import Foundation
import Testing
@testable import AgentPetCore

private final class PiSandbox {
    let home: URL
    var extensionURL: URL { home.appendingPathComponent(".pi/agent/extensions/agentpet.ts") }

    init() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentpet-pi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: home) }

    func configurator() -> PiConfigurator {
        PiConfigurator(
            home: home,
            transaction: ConfigTransaction(
                backupDirectory: home.appendingPathComponent("backups")
            )
        )
    }

    func fileText() -> String? {
        (try? Data(contentsOf: extensionURL)).flatMap { String(data: $0, encoding: .utf8) }
    }

    func writeForeignFile() throws {
        try FileManager.default.createDirectory(
            at: extensionURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("// my own extension\nexport default function (pi) {}\n".utf8)
            .write(to: extensionURL)
    }
}

private let piShim = "/opt/agentpet/agentpet-hook"
private let piNow = Date(timeIntervalSince1970: 1_700_000_000)

@Suite("Pi configuration")
struct PiConfigurationTests {

    @Test("every event the extension sends is one the normalizer knows about")
    func emittedEventsAreKnown() throws {
        // Read off the generated file rather than from a list written here: the
        // template takes the event set as a parameter, so a wrong parameter
        // would leave the file sending events the profile cannot map — and a
        // hand-written list would not notice.
        let source = PiConfigurator.template(shimPath: piShim)
        let rules = try #require(AgentProfiles.profile(for: "pi"))
        let known = Set(rules.rules.flatMap(\.matches))

        // Pinned, not derived: reading the expectation out of the file under
        // test would shrink it when a registration goes missing — delete the
        // two Pi-specific ones and the parse below still returns the four in
        // the shared prologue, every one of which the profile knows.
        let pinned: Set<String> = [
            "session_start", "agent_start", "tool_execution_start",
            "ui_prompt_start", "agent_settled", "session_shutdown",
        ]
        let listened = listenedEvents(inGeneratedFile: source)
        #expect(listened == pinned, "the file registers \(listened.sorted())")
        for event in pinned {
            #expect(known.contains(event), "\(event) is listened for but unknown to the normalizer")
        }
        // The reading rides out of the settle handler rather than off an event
        // of its own, so it is sent, not listened for.
        #expect(source.contains("send(\"context_update\""), "the context reading is never sent")
        #expect(known.contains("context_update"), "context_update is sent but unknown")
    }

    @Test("the extension hands the payload over in the environment, not on a pipe")
    func payloadGoesThroughTheEnvironment() throws {
        // Ported from PR #1's finding: a write to a pipe from inside the
        // agent's runtime queues on the agent's event loop, and the shim's
        // stdin wait expires before it lands — the event then arrives with no
        // session at all.
        let template = PiConfigurator.template(shimPath: piShim)
        #expect(template.contains("AGENTPET_PAYLOAD_BASE64"))
        // `child.stdin`, which is what a pipe write here would go through:
        // asserting `proc.stdin` can never fail, because the generated file
        // names no `proc` at all.
        #expect(!template.contains("child.stdin"), "the payload must not depend on a pipe write")
    }

    @Test("configuring writes one marked file and nothing else")
    func installs() throws {
        let sandbox = try PiSandbox()
        let outcome = try sandbox.configurator().configure(shimPath: piShim, replacing: nil, now: piNow)

        #expect(outcome.didChange)
        #expect(outcome.record.isConfigured)
        let text = try #require(sandbox.fileText())
        #expect(text.contains(PiConfigurator.marker))
        #expect(text.contains(piShim))
        // The spawned command names the agent, in both places it can: the
        // argv the shim is called with, and the constant the file reads it
        // from. Asserting only "--agent" and "pi" separately was true of any
        // file at all (`export default function (pi)` carries "pi").
        #expect(text.contains("--agent pi"))
        #expect(text.contains("const AGENT = \"pi\";"))
        #expect(sandbox.configurator().entriesPresent(in: outcome.record))

        // The only thing under home is Pi's own directory: no settings edit,
        // no backup (nothing existed to back up), no package.
        let top = try FileManager.default.contentsOfDirectory(atPath: sandbox.home.path)
        #expect(top == [".pi"])
    }

    @Test("configuring twice changes nothing")
    func idempotent() throws {
        let sandbox = try PiSandbox()
        let configurator = sandbox.configurator()
        _ = try configurator.configure(shimPath: piShim, replacing: nil, now: piNow)
        let second = try configurator.configure(shimPath: piShim, replacing: nil, now: piNow)
        #expect(!second.didChange)
    }

    @Test("a moved shim shows up as drift")
    func movedShimIsDrift() throws {
        let sandbox = try PiSandbox()
        let outcome = try sandbox.configurator().configure(shimPath: piShim, replacing: nil, now: piNow)

        var moved = outcome.record
        moved.shimPath = "/somewhere/else/agentpet-hook"
        #expect(!sandbox.configurator().entriesPresent(in: moved))
    }

    @Test("a file the user wrote is refused, never overwritten")
    func refusesForeignFile() throws {
        let sandbox = try PiSandbox()
        try sandbox.writeForeignFile()
        let before = sandbox.fileText()

        #expect(throws: ConfigurationError.self) {
            _ = try sandbox.configurator().configure(shimPath: piShim, replacing: nil, now: piNow)
        }
        #expect(sandbox.fileText() == before)
    }

    @Test("uninstalling deletes the runtime's file, with a backup")
    func uninstallDeletes() throws {
        let sandbox = try PiSandbox()
        let configurator = sandbox.configurator()
        let installed = try configurator.configure(shimPath: piShim, replacing: nil, now: piNow)

        let removed = try configurator.uninstall(installed.record, now: piNow)

        #expect(removed.didChange)
        #expect(removed.record.status == .notConfigured)
        #expect(!FileManager.default.fileExists(atPath: sandbox.extensionURL.path))
        let backups = try FileManager.default.contentsOfDirectory(
            atPath: sandbox.home.appendingPathComponent("backups").path
        )
        #expect(backups.count == 1, "the deleted file must exist in the backup directory")
    }

    @Test("uninstall leaves a file the runtime did not write alone")
    func uninstallLeavesForeignFile() throws {
        let sandbox = try PiSandbox()
        try sandbox.writeForeignFile()
        let before = sandbox.fileText()
        let record = IntegrationRecord(
            agentID: "pi", status: .configured,
            shimPath: piShim,
            entries: [WrittenEntry(file: sandbox.extensionURL.path, event: "extension", command: PiConfigurator.marker)]
        )

        let outcome = try sandbox.configurator().uninstall(record, now: piNow)

        #expect(!outcome.didChange)
        #expect(sandbox.fileText() == before)
    }
}
