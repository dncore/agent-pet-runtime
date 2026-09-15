import Foundation
import Testing
@testable import AgentPetCore

private final class ConfigSandbox {
    let root: URL
    let settings: URL

    init(existing: String? = nil) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentpet-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        settings = root.appendingPathComponent("settings.json")
        if let existing { try Data(existing.utf8).write(to: settings) }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var transaction: ConfigTransaction {
        ConfigTransaction(backupDirectory: root.appendingPathComponent("backups"), maxBackups: 5)
    }

    func configurator(events: [String] = ["Stop", "PreToolUse"]) -> JSONHookConfigurator {
        JSONHookConfigurator(
            agentID: "claude-code",
            configURL: settings,
            events: events,
            transaction: transaction
        )
    }

    func object() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: settings))) as? [String: Any] ?? [:]
    }

    func commands(for event: String) -> [String] {
        let hooks = object()["hooks"] as? [String: Any]
        let entries = hooks?[event] as? [[String: Any]] ?? []
        return entries.flatMap { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }
}

private let shim = "/opt/agentpet/agentpet-hook"
private let now = Date(timeIntervalSince1970: 1_700_000_000)

@Suite("Hook installation")
struct HookInstallationTests {

    @Test("configuring installs a hook for every event")
    func installsAllEvents() throws {
        let sandbox = try ConfigSandbox(existing: "{}")
        let outcome = try sandbox.configurator().configure(shimPath: shim, replacing: nil, now: now)

        #expect(outcome.didChange)
        #expect(outcome.record.isConfigured)
        #expect(sandbox.commands(for: "Stop").count == 1)
        #expect(sandbox.commands(for: "PreToolUse").count == 1)
        #expect(outcome.record.entries.count == 2)
    }

    @Test("the installed command names its agent and event explicitly")
    func commandIsExplicit() throws {
        let sandbox = try ConfigSandbox(existing: "{}")
        _ = try sandbox.configurator(events: ["Stop"]).configure(shimPath: shim, replacing: nil, now: now)
        let command = try #require(sandbox.commands(for: "Stop").first)
        #expect(command.contains(shim))
        #expect(command.contains("--agent claude-code"))
        #expect(command.contains("--event Stop"))
    }

    @Test("configuring twice does not duplicate anything")
    func idempotent() throws {
        let sandbox = try ConfigSandbox(existing: "{}")
        let configurator = sandbox.configurator()

        let first = try configurator.configure(shimPath: shim, replacing: nil, now: now)
        let second = try configurator.configure(shimPath: shim, replacing: first.record, now: now)

        #expect(!second.didChange, "the second configure must be a no-op")
        #expect(sandbox.commands(for: "Stop").count == 1)
    }

    @Test("configuring three times still leaves exactly one hook")
    func idempotentRepeatedly() throws {
        let sandbox = try ConfigSandbox(existing: "{}")
        let configurator = sandbox.configurator()
        var record: IntegrationRecord?

        for _ in 0..<3 {
            record = try configurator.configure(shimPath: shim, replacing: record, now: now).record
        }
        #expect(sandbox.commands(for: "Stop").count == 1)
        #expect(sandbox.commands(for: "PreToolUse").count == 1)
    }

    @Test("a hook the user wrote is preserved and left alone")
    func userHooksPreserved() throws {
        let sandbox = try ConfigSandbox(existing: """
        {"hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"/user/own.sh"}]}]}}
        """)
        _ = try sandbox.configurator(events: ["Stop"]).configure(shimPath: shim, replacing: nil, now: now)

        let commands = sandbox.commands(for: "Stop")
        #expect(commands.contains("/user/own.sh"))
        #expect(commands.contains { $0.contains("agentpet-hook") })
    }

    @Test("unrelated settings survive untouched")
    func unrelatedSettingsSurvive() throws {
        let sandbox = try ConfigSandbox(existing: """
        {"model":"opus","permissions":{"allow":["Bash(git *)"]},"env":{"FOO":"bar"}}
        """)
        _ = try sandbox.configurator().configure(shimPath: shim, replacing: nil, now: now)

        let result = sandbox.object()
        #expect(result["model"] as? String == "opus")
        #expect((result["env"] as? [String: String])?["FOO"] == "bar")
        #expect(result["hooks"] != nil)
    }

    @Test("a moved runtime replaces its old hook rather than adding a second")
    func relocationReplaces() throws {
        let sandbox = try ConfigSandbox(existing: "{}")
        let configurator = sandbox.configurator(events: ["Stop"])

        let first = try configurator.configure(
            shimPath: "/old/path/agentpet-hook", replacing: nil, now: now
        )
        #expect(sandbox.commands(for: "Stop").count == 1)

        // The app was reinstalled somewhere else and Configure is run again.
        _ = try configurator.configure(
            shimPath: "/Applications/AgentPet.app/agentpet-hook",
            replacing: first.record,
            now: now
        )

        let commands = sandbox.commands(for: "Stop")
        #expect(commands.count == 1, "the stale hook was not removed: \(commands)")
        #expect(commands.first?.contains("/Applications/") == true)
    }
}

@Suite("Hook removal")
struct HookRemovalTests {

    @Test("uninstalling removes exactly what was installed")
    func removesOwnEntries() throws {
        let sandbox = try ConfigSandbox(existing: "{}")
        let configurator = sandbox.configurator()

        let outcome = try configurator.configure(shimPath: shim, replacing: nil, now: now)
        #expect(!sandbox.commands(for: "Stop").isEmpty)

        _ = try configurator.uninstall(outcome.record, now: now)
        #expect(sandbox.commands(for: "Stop").isEmpty)
        #expect(sandbox.commands(for: "PreToolUse").isEmpty)
    }

    @Test("uninstalling never removes a hook the user wrote")
    func userHooksSurviveUninstall() throws {
        let sandbox = try ConfigSandbox(existing: """
        {"hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"/user/own.sh"}]}]}}
        """)
        let configurator = sandbox.configurator(events: ["Stop"])

        let outcome = try configurator.configure(shimPath: shim, replacing: nil, now: now)
        #expect(sandbox.commands(for: "Stop").count == 2)

        _ = try configurator.uninstall(outcome.record, now: now)

        let remaining = sandbox.commands(for: "Stop")
        #expect(remaining == ["/user/own.sh"], "expected only the user's hook left, got \(remaining)")
    }

    @Test("uninstalling a record whose entries are already gone is a safe no-op")
    func uninstallWhenAlreadyGone() throws {
        let sandbox = try ConfigSandbox(existing: "{}")
        let configurator = sandbox.configurator()
        let outcome = try configurator.configure(shimPath: shim, replacing: nil, now: now)

        _ = try configurator.uninstall(outcome.record, now: now)
        let second = try configurator.uninstall(outcome.record, now: now)

        #expect(!second.didChange)
        #expect(sandbox.commands(for: "Stop").isEmpty)
    }

    @Test("an install from a since-moved runtime can still be removed")
    func removesRecordedPathNotCurrentOne() throws {
        let sandbox = try ConfigSandbox(existing: "{}")
        let configurator = sandbox.configurator(events: ["Stop"])

        // Installed from a path that no longer exists.
        let old = try configurator.configure(
            shimPath: "/Applications/Deleted AgentPet.app/agentpet-hook",
            replacing: nil, now: now
        )
        _ = try configurator.uninstall(old.record, now: now)
        #expect(sandbox.commands(for: "Stop").isEmpty,
                "removal must match the recorded command, not the current shim path")
    }

    @Test("entriesPresent reports truthfully after removal")
    func entriesPresentAfterRemoval() throws {
        let sandbox = try ConfigSandbox(existing: "{}")
        let configurator = sandbox.configurator(events: ["Stop"])
        let outcome = try configurator.configure(shimPath: shim, replacing: nil, now: now)

        #expect(configurator.entriesPresent(in: outcome.record))
        _ = try configurator.uninstall(outcome.record, now: now)
        #expect(!configurator.entriesPresent(in: outcome.record))
    }
}

@Suite("Hook installation against a real-shaped settings file")
struct RealisticSettingsTests {

    @Test("a round trip through a Claude-Code-shaped file is clean")
    func roundTrip() throws {
        // Modelled on the shape of a real ~/.claude/settings.json.
        let sandbox = try ConfigSandbox(existing: """
        {
          "env": { "CLAUDE_CODE_EFFORT_LEVEL": "max" },
          "permissions": { "allow": ["Bash(git add *)", "Bash(npm run *)"] },
          "hooks": {
            "Stop": [
              { "matcher": "*", "hooks": [ { "type": "command", "command": "/usr/local/bin/notify.sh" } ] }
            ]
          }
        }
        """)
        let before = try Data(contentsOf: sandbox.settings)

        let configurator = sandbox.configurator(events: ["Stop", "PreToolUse"])
        let outcome = try configurator.configure(shimPath: shim, replacing: nil, now: now)

        #expect(outcome.didChange)
        #expect(outcome.backupURLs.count == 1)

        // Everything the user had is still there.
        let result = sandbox.object()
        #expect((result["permissions"] as? [String: Any])?["allow"] != nil)
        #expect(sandbox.commands(for: "Stop").contains("/usr/local/bin/notify.sh"))
        #expect(sandbox.commands(for: "Stop").count == 2)

        // And a full removal returns the file to its original meaning.
        _ = try configurator.uninstall(outcome.record, now: now)
        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: sandbox.settings))
        let original = try JSONSerialization.jsonObject(with: before)
        #expect(NSDictionary(dictionary: restored as? [String: Any] ?? [:])
            .isEqual(to: original as? [String: Any] ?? [:]),
                "after install+uninstall the settings should mean the same thing")
    }

    @Test("a corrupt settings file is refused, not overwritten")
    func corruptFileRefused() throws {
        let sandbox = try ConfigSandbox(existing: "{ this is not valid json")
        let before = try Data(contentsOf: sandbox.settings)

        #expect(throws: ConfigTransactionError.self) {
            _ = try sandbox.configurator().configure(shimPath: shim, replacing: nil, now: now)
        }
        #expect(try Data(contentsOf: sandbox.settings) == before)
    }

    @Test("a settings file that does not exist yet is created")
    func missingFileCreated() throws {
        let sandbox = try ConfigSandbox()
        _ = try sandbox.configurator(events: ["Stop"]).configure(shimPath: shim, replacing: nil, now: now)
        #expect(sandbox.commands(for: "Stop").count == 1)
    }
}

@Suite("Integration health")
struct IntegrationHealthTests {

    private let evaluator = IntegrationHealthEvaluator()
    private let configured = IntegrationRecord(
        agentID: "claude-code",
        status: .configured,
        shimPath: shim,
        entries: [WrittenEntry(file: "/tmp/s.json", event: "Stop", command: "cmd")]
    )

    @Test("an undetected agent reports as such whatever else is true")
    func notDetected() {
        let health = evaluator.health(
            record: configured, isDetected: false, lastEventAt: now,
            entriesPresent: true
        )
        #expect(health == .notDetected)
    }

    @Test("a detected but unconfigured agent invites configuration")
    func detectedOnly() {
        let health = evaluator.health(
            record: IntegrationRecord(agentID: "x"), isDetected: true,
            lastEventAt: nil, entriesPresent: false
        )
        #expect(health == .detected)
    }

    @Test("an event that has arrived at all means connected")
    func connected() {
        let health = evaluator.health(
            record: configured, isDetected: true,
            lastEventAt: now.addingTimeInterval(-10), entriesPresent: true
        )
        #expect(health == .connected)
        #expect(health.isHealthy)
    }

    @Test("an agent that was heard from an hour ago is still connected")
    func quietIsNotDegraded() {
        // The regression this exists for: hooks fire around turns, so silence
        // is what a healthy integration looks like between them. Judging it as
        // degradation made the card cry wolf every time the user stopped to
        // read an answer — and after a restart, when the timestamp lived only
        // in memory, it did so immediately.
        let health = evaluator.health(
            record: configured, isDetected: true,
            lastEventAt: now.addingTimeInterval(-3600), entriesPresent: true
        )
        #expect(health == .connected)
        #expect(health.isHealthy)
    }

    @Test("configured but never any event deserves attention")
    func neverHeardFrom() {
        let health = evaluator.health(
            record: configured, isDetected: true,
            lastEventAt: nil, entriesPresent: true
        )
        #expect(health == .degraded)
        #expect(!health.isHealthy)
    }

    @Test("our entries disappearing from the file needs attention")
    func disconnected() {
        let health = evaluator.health(
            record: configured, isDetected: true,
            lastEventAt: now, entriesPresent: false
        )
        #expect(health == .disconnected)
    }

    @Test("a failure outranks everything else")
    func failureWins() {
        let health = evaluator.health(
            record: configured, isDetected: true, lastEventAt: now,
            entriesPresent: true, failure: "permission denied"
        )
        #expect(health == .failed("permission denied"))
    }
}

@Suite("Agent integration registry")
struct AgentIntegrationRegistryTests {

    private var transaction: ConfigTransaction {
        ConfigTransaction(backupDirectory: URL(fileURLWithPath: "/tmp/agentpet-registry-test"))
    }

    @Test("every registered agent has a unique id")
    func uniqueIDs() {
        let ids = AgentIntegrationRegistry.all(transaction: transaction).map(\.agentID)
        #expect(Set(ids).count == ids.count)
    }

    @Test("an agent with no configurator does not claim the configure capability")
    func capabilitiesMatchReality() {
        for profile in AgentIntegrationRegistry.all(transaction: transaction) {
            if profile.configurator == nil {
                #expect(!profile.capabilities.contains(.configure),
                        "\(profile.agentID) has no configurator but claims it can configure")
                #expect(!profile.capabilities.contains(.uninstall),
                        "\(profile.agentID) has no configurator but claims it can uninstall")
            } else {
                #expect(profile.capabilities.contains(.configure))
                #expect(profile.capabilities.contains(.uninstall))
            }
        }
    }

    @Test("an agent with no configurator explains why, in its own words")
    func unconfigurableAgentsExplainThemselves() {
        var seen = Set<String>()
        for profile in AgentIntegrationRegistry.all(transaction: transaction)
        where profile.configurator == nil {
            let note = profile.configurationNote ?? ""
            #expect(!note.isEmpty, "\(profile.agentID) is not configurable and says nothing about it")
            // Every agent registered today has a configurator, so this loop is
            // idle; the uniqueness check stays armed for the next agent that
            // arrives without one.
            #expect(seen.insert(note).inserted, "\(profile.agentID) reuses another agent's note")
        }
    }

    @Test("no agent claims focusSession, which v0.1 cannot deliver")
    func focusNotClaimed() {
        for profile in AgentIntegrationRegistry.all(transaction: transaction) {
            #expect(!profile.capabilities.contains(.focusSession),
                    "\(profile.agentID) claims focusSession, but hooks carry no window identity")
        }
    }

    @Test("Codex's post-configure hint names the step it is asking for")
    func codexTrustHint() throws {
        let profile = try #require(
            AgentIntegrationRegistry.profile(for: "codex", transaction: transaction)
        )
        let hint = try #require(profile.postConfigureHint)
        #expect(hint.contains("/hooks"),
                "the hint has to name Codex's own review step, not gesture at it")
        #expect(profile.configurator != nil)
    }

    @Test("every installed event is one the normalizer knows about")
    func installedEventsAreKnown() throws {
        for profile in AgentIntegrationRegistry.all(transaction: transaction) {
            guard let configurator = profile.configurator as? JSONHookConfigurator,
                  let normalization = AgentProfiles.profile(for: profile.agentID)
            else { continue }
            let known = Set(normalization.rules.flatMap(\.matches))

            for event in configurator.events {
                #expect(known.contains(event),
                        "\(profile.agentID): \(event) is installed but unknown to the normalizer")
            }
        }
    }
}
