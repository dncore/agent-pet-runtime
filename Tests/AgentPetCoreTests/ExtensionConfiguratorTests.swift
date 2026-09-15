import Foundation
import Testing
@testable import AgentPetCore

private let ompEpoch = Date(timeIntervalSince1970: 1_700_000_000)
private let ompShim = "/Applications/AgentPet.app/Contents/MacOS/agentpet-hook"

/// A throwaway home whose `.omp/agent/extensions` directory is the target.
private final class ExtensionSandbox {
    let root: URL
    let extensions: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentpet-omp-\(UUID().uuidString)")
        extensions = root.appendingPathComponent(".omp/agent/extensions")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var transaction: ConfigTransaction {
        ConfigTransaction(backupDirectory: root.appendingPathComponent("backups"), maxBackups: 5)
    }

    func configurator() -> ExtensionFileConfigurator {
        ExtensionFileConfigurator(agentID: "omp", directory: extensions, transaction: transaction)
    }

    var fileURL: URL { extensions.appendingPathComponent(AgentPetExtension.fileName) }

    func text() -> String? { try? String(contentsOf: fileURL, encoding: .utf8) }

    func writeForeignFile() throws {
        try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
        try Data("export default function (pi) { pi.on(\"session_start\", () => {}); }\n".utf8)
            .write(to: fileURL)
    }

    func backups() -> [URL] {
        let directory = root.appendingPathComponent("backups")
        return (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
    }
}

@Suite("Oh My Pi extension installation")
struct ExtensionInstallationTests {

    @Test("configuring writes one extension file, creating the directory")
    func installsTheFile() throws {
        let sandbox = try ExtensionSandbox()
        let outcome = try sandbox.configurator().configure(shimPath: ompShim, replacing: nil, now: ompEpoch)

        #expect(outcome.didChange)
        #expect(outcome.record.isConfigured)
        #expect(outcome.changedFiles == [sandbox.fileURL.path])
        #expect(FileManager.default.fileExists(atPath: sandbox.fileURL.path))

        let text = try #require(sandbox.text())
        #expect(text.contains(AgentPetExtension.ownershipMarker))
        #expect(text.contains(AgentPetExtension.markerLine(agentID: "omp", shimPath: ompShim)))
        #expect(text.contains("--agent omp"))
        // The loader imports the file and calls what it default-exports; a file
        // without one is not an extension at all.
        #expect(text.contains("export default function (pi)"))
    }

    @Test("the extension reports and never gates, injects, or writes")
    func reportsOnly() throws {
        let sandbox = try ExtensionSandbox()
        _ = try sandbox.configurator().configure(shimPath: ompShim, replacing: nil, now: ompEpoch)
        let text = try #require(sandbox.text())

        // The three ways an in-process extension could change the agent: block
        // a tool (fail-closed), inject a message into the session, or touch the
        // user's files. The blocking check is for the result shape omp honours
        // — `{ block: true }` — since the prose above is allowed to say the
        // word.
        #expect(!text.contains("block:"), "the extension must never return a blocking result")
        #expect(!text.contains("sendMessage"), "the extension must never inject messages")
        #expect(!text.contains("writeFile") && !text.contains("node:fs"))
        // No modal UI either: a pet that could open a prompt inside the agent
        // would be running the agent rather than watching it.
        #expect(!text.contains("ctx.ui"))
    }

    @Test("the extension hands the payload over in the environment, not on a pipe")
    func payloadGoesThroughTheEnvironment() throws {
        let sandbox = try ExtensionSandbox()
        _ = try sandbox.configurator().configure(shimPath: ompShim, replacing: nil, now: ompEpoch)
        let text = try #require(sandbox.text())

        #expect(text.contains("AGENTPET_PAYLOAD_BASE64"))
        // A pipe write from inside the agent's runtime is queued on an event
        // loop the agent may be holding, and the shim stops waiting for stdin
        // after 20ms: an event whose payload misses that window arrives with no
        // session id at all. Writing to stdin here would reintroduce exactly
        // that (measured: 30ms of block was enough to lose it).
        #expect(!text.contains("child.stdin"), "the payload must not depend on a pipe write")
    }

    @Test("configuring twice rewrites nothing")
    func idempotent() throws {
        let sandbox = try ExtensionSandbox()
        let configurator = sandbox.configurator()

        let first = try configurator.configure(shimPath: ompShim, replacing: nil, now: ompEpoch)
        let before = try #require(sandbox.text())
        let second = try configurator.configure(shimPath: ompShim, replacing: first.record, now: ompEpoch)

        #expect(!second.didChange, "the second configure must be a no-op")
        #expect(second.changedFiles.isEmpty)
        #expect(sandbox.text() == before)
        #expect(sandbox.backups().isEmpty, "a no-op must not leave a backup behind")
    }

    @Test("a moved runtime replaces the file rather than adding a second one")
    func relocationReplaces() throws {
        let sandbox = try ExtensionSandbox()
        let configurator = sandbox.configurator()

        let first = try configurator.configure(
            shimPath: "/old/path/agentpet-hook", replacing: nil, now: ompEpoch
        )
        let second = try configurator.configure(
            shimPath: ompShim, replacing: first.record, now: ompEpoch
        )

        let text = try #require(sandbox.text())
        #expect(text.contains(ompShim))
        #expect(!text.contains("/old/path/agentpet-hook"))
        #expect(configurator.entriesPresent(in: second.record))
        // One extension per file: a second copy under a second name is the
        // failure mode this rules out.
        let installed = try FileManager.default.contentsOfDirectory(atPath: sandbox.extensions.path)
        #expect(installed == [AgentPetExtension.fileName])
    }

    @Test("a file the runtime did not write is refused, not clobbered")
    func foreignFileRefused() throws {
        let sandbox = try ExtensionSandbox()
        try sandbox.writeForeignFile()
        let before = try #require(sandbox.text())

        #expect(throws: ConfigurationError.foreignFile(sandbox.fileURL.path)) {
            _ = try sandbox.configurator().configure(shimPath: ompShim, replacing: nil, now: ompEpoch)
        }
        #expect(sandbox.text() == before, "somebody else's extension was overwritten")
    }

    @Test("a file that is not even text is refused too")
    func undecodableFileRefused() throws {
        // It cannot be ours — ours is generated ASCII — so the ownership check
        // must not be skipped just because it failed to decode.
        let sandbox = try ExtensionSandbox()
        try FileManager.default.createDirectory(at: sandbox.extensions, withIntermediateDirectories: true)
        let bytes = Data([0xFF, 0xFE, 0x00, 0x41, 0x80])
        try bytes.write(to: sandbox.fileURL)

        #expect(throws: ConfigurationError.foreignFile(sandbox.fileURL.path)) {
            _ = try sandbox.configurator().configure(shimPath: ompShim, replacing: nil, now: ompEpoch)
        }
        #expect(try Data(contentsOf: sandbox.fileURL) == bytes)
    }

    @Test("a file an older runtime wrote is still recognised as ours")
    func olderBuildIsOurs() throws {
        // The ownership marker is version- and path-independent: a file written
        // before the app moved must be replaceable, not refused.
        let sandbox = try ExtensionSandbox()
        try FileManager.default.createDirectory(at: sandbox.extensions, withIntermediateDirectories: true)
        try Data("\(AgentPetExtension.ownershipMarker) — from an older build\n".utf8)
            .write(to: sandbox.fileURL)

        let outcome = try sandbox.configurator().configure(shimPath: ompShim, replacing: nil, now: ompEpoch)
        #expect(outcome.didChange)
        #expect(try #require(sandbox.text()).contains(ompShim))
    }

    @Test("entriesPresent reports truthfully as the file is replaced")
    func entriesPresentTracksContent() throws {
        let sandbox = try ExtensionSandbox()
        let configurator = sandbox.configurator()

        let first = try configurator.configure(
            shimPath: "/old/path/agentpet-hook", replacing: nil, now: ompEpoch
        )
        #expect(configurator.entriesPresent(in: first.record))

        // The runtime moved and Configure was run again: the old record's shim
        // line is gone, so that install is no longer reported as present — the
        // same "disconnected until reconfigured" rule the hook installs follow.
        let second = try configurator.configure(shimPath: ompShim, replacing: first.record, now: ompEpoch)
        #expect(!configurator.entriesPresent(in: first.record))
        #expect(configurator.entriesPresent(in: second.record))

        // And a record that claims an entry the file never had is not believed.
        let fabricated = IntegrationRecord(
            agentID: "omp",
            status: .configured,
            shimPath: ompShim,
            entries: [WrittenEntry(
                file: sandbox.fileURL.path, event: "agentpet.ts", command: "// shim: /nowhere"
            )]
        )
        #expect(!configurator.entriesPresent(in: fabricated))
    }

    @Test("a path with a quote or a backslash still produces a working file")
    func awkwardPathEscaped() throws {
        let sandbox = try ExtensionSandbox()
        let awkward = "/tmp/o\"brien\\agent pet/agentpet-hook"
        _ = try sandbox.configurator().configure(shimPath: awkward, replacing: nil, now: ompEpoch)

        let text = try #require(sandbox.text())
        let shimLine = try #require(text.split(separator: "\n").first { $0.hasPrefix("const SHIM") })
        #expect(shimLine.contains("\\\""), "the quote was not escaped: \(shimLine)")
        #expect(shimLine.contains("\\\\"), "the backslash was not escaped: \(shimLine)")
    }

    @Test("the string literal escapes exactly what JavaScript needs escaped")
    func stringLiteralEscaping() {
        #expect(AgentPetExtension.jsStringLiteral("/plain/path") == "\"/plain/path\"")
        #expect(AgentPetExtension.jsStringLiteral("a\"b") == "\"a\\\"b\"")
        #expect(AgentPetExtension.jsStringLiteral("a\\b") == "\"a\\\\b\"")
        #expect(AgentPetExtension.jsStringLiteral("a\nb") == "\"a\\nb\"")
        #expect(AgentPetExtension.jsStringLiteral("a\u{01}b") == "\"a\\u0001b\"")
    }
}

@Suite("Oh My Pi extension removal")
struct ExtensionRemovalTests {

    @Test("uninstalling deletes the file, keeping a copy of it")
    func removesTheFile() throws {
        let sandbox = try ExtensionSandbox()
        let configurator = sandbox.configurator()
        let outcome = try configurator.configure(shimPath: ompShim, replacing: nil, now: ompEpoch)

        let removal = try configurator.uninstall(outcome.record, now: ompEpoch)
        #expect(removal.didChange)
        #expect(removal.changedFiles == [sandbox.fileURL.path])
        #expect(!removal.record.isConfigured)
        #expect(!FileManager.default.fileExists(atPath: sandbox.fileURL.path))
        #expect(sandbox.backups().count == 1, "deleting a file must be reversible")
        #expect(!configurator.entriesPresent(in: outcome.record))
        // The directory is the agent's, not ours: an empty extensions
        // directory is what "no extensions" looks like.
        #expect(FileManager.default.fileExists(atPath: sandbox.extensions.path))
    }

    @Test("uninstalling twice is a safe no-op")
    func uninstallWhenAlreadyGone() throws {
        let sandbox = try ExtensionSandbox()
        let configurator = sandbox.configurator()
        let outcome = try configurator.configure(shimPath: ompShim, replacing: nil, now: ompEpoch)

        _ = try configurator.uninstall(outcome.record, now: ompEpoch)
        let second = try configurator.uninstall(outcome.record, now: ompEpoch)

        #expect(!second.didChange)
        #expect(second.changedFiles.isEmpty)
    }

    @Test("a file that is no longer ours is left where it is")
    func foreignFileSurvivesUninstall() throws {
        let sandbox = try ExtensionSandbox()
        let configurator = sandbox.configurator()
        let outcome = try configurator.configure(shimPath: ompShim, replacing: nil, now: ompEpoch)

        // The user edited it into something of their own.
        try Data("export default function (pi) { /* mine now */ }\n".utf8).write(to: sandbox.fileURL)

        let removal = try configurator.uninstall(outcome.record, now: ompEpoch)
        #expect(!removal.didChange, "a file without our marker is not ours to delete")
        #expect(FileManager.default.fileExists(atPath: sandbox.fileURL.path))
    }

    @Test("a moved runtime's install can still be removed")
    func removesRecordedPathNotCurrentOne() throws {
        let sandbox = try ExtensionSandbox()
        let configurator = sandbox.configurator()

        // Installed from a path that no longer exists.
        let old = try configurator.configure(
            shimPath: "/Applications/Deleted AgentPet.app/agentpet-hook",
            replacing: nil, now: ompEpoch
        )
        _ = try configurator.uninstall(old.record, now: ompEpoch)
        #expect(!FileManager.default.fileExists(atPath: sandbox.fileURL.path),
                "removal must match the recorded marker, not the current shim path")
    }

    @Test("a record with no entries removes nothing")
    func emptyRecordRemovesNothing() throws {
        let sandbox = try ExtensionSandbox()
        let configurator = sandbox.configurator()
        _ = try configurator.configure(shimPath: ompShim, replacing: nil, now: ompEpoch)

        let removal = try configurator.uninstall(IntegrationRecord(agentID: "omp"), now: ompEpoch)
        #expect(!removal.didChange)
        #expect(FileManager.default.fileExists(atPath: sandbox.fileURL.path))
    }
}
