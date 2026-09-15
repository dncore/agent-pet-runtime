import Foundation
import Testing
@testable import AgentPetCore

/// A scratch directory that cleans itself up.
private final class Sandbox {
    let root: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentpet-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var backups: URL { root.appendingPathComponent("backups") }

    func file(_ name: String, _ contents: String? = nil) throws -> URL {
        let url = root.appendingPathComponent(name)
        if let contents { try Data(contents.utf8).write(to: url) }
        return url
    }

    func read(_ url: URL) -> String {
        (try? String(decoding: Data(contentsOf: url), as: UTF8.self)) ?? ""
    }

    func readObject(_ url: URL) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
    }
}

private func transaction(_ sandbox: Sandbox) -> ConfigTransaction {
    ConfigTransaction(backupDirectory: sandbox.backups, maxBackups: 3)
}

@Suite("Config transaction — happy path")
struct ConfigTransactionHappyPathTests {

    @Test("editing an existing file writes the change and backs up the original")
    func editsAndBacksUp() throws {
        let sandbox = try Sandbox()
        let file = try sandbox.file("settings.json", #"{"existing":true}"#)
        let originalBytes = try Data(contentsOf: file)

        let outcome = try transaction(sandbox).perform(on: file) { object in
            object["added"] = "yes"
        }

        #expect(outcome.didChange)
        #expect(outcome.backupURL != nil)
        let result = sandbox.readObject(file)
        #expect(result["added"] as? String == "yes")
        #expect(result["existing"] as? Bool == true, "unrelated keys must survive")

        let backup = try Data(contentsOf: #require(outcome.backupURL))
        #expect(backup == originalBytes, "the backup must be byte-identical to the original")
    }

    @Test("creating a file that does not exist yet")
    func createsNewFile() throws {
        let sandbox = try Sandbox()
        let file = sandbox.root.appendingPathComponent("new.json")

        let outcome = try transaction(sandbox).perform(on: file) { object in
            object["hooks"] = ["a"]
        }

        #expect(outcome.didChange)
        #expect(outcome.backupURL == nil, "there was nothing to back up")
        #expect(sandbox.readObject(file)["hooks"] as? [String] == ["a"])
    }

    @Test("an edit that changes nothing reports no change and writes nothing")
    func noOpIsReported() throws {
        let sandbox = try Sandbox()
        let file = try sandbox.file("settings.json", #"{"a":1}"#)
        let before = try Data(contentsOf: file)

        let outcome = try transaction(sandbox).perform(on: file) { _ in }

        #expect(!outcome.didChange)
        #expect(outcome.backupURL == nil, "a no-op must not create backup churn")
        #expect(try Data(contentsOf: file) == before)
    }

    @Test("the result is valid JSON")
    func resultIsValidJSON() throws {
        let sandbox = try Sandbox()
        let file = try sandbox.file("settings.json", #"{"a":1}"#)
        try transaction(sandbox).perform(on: file) { $0["b"] = ["nested": ["deep": true]] }
        #expect((try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) != nil)
    }

    @Test("a file that did not exist is removed again on rollback, not left empty")
    func rollbackRemovesCreatedFile() throws {
        let sandbox = try Sandbox()
        let file = sandbox.root.appendingPathComponent("new.json")
        let tx = transaction(sandbox)

        let snapshot = try tx.snapshot(file)
        try tx.perform(on: file) { $0["x"] = 1 }
        #expect(FileManager.default.fileExists(atPath: file.path))

        try tx.rollback(to: snapshot)
        #expect(!FileManager.default.fileExists(atPath: file.path),
                "leaving an empty object behind would be a change we invented")
    }
}

@Suite("Config transaction — refusals")
struct ConfigTransactionRefusalTests {

    @Test("an unparseable file is refused rather than overwritten")
    func malformedFileRefused() throws {
        let sandbox = try Sandbox()
        let file = try sandbox.file("settings.json", "{ this is not json")
        let before = try Data(contentsOf: file)

        #expect(throws: ConfigTransactionError.self) {
            try transaction(sandbox).perform(on: file) { $0["added"] = true }
        }
        #expect(try Data(contentsOf: file) == before, "the file must be untouched")
    }

    @Test("a JSON array at the top level is refused")
    func nonObjectRefused() throws {
        let sandbox = try Sandbox()
        let file = try sandbox.file("settings.json", "[1,2,3]")
        #expect(throws: ConfigTransactionError.self) {
            try transaction(sandbox).perform(on: file) { $0["added"] = true }
        }
    }

    @Test("a concurrent write is detected and the file is not clobbered")
    func concurrentModificationDetected() throws {
        let sandbox = try Sandbox()
        let file = try sandbox.file("settings.json", #"{"version":1}"#)
        let tx = transaction(sandbox)

        // Another process writes between our snapshot and our write.
        var writeAttempted = false
        #expect(throws: ConfigTransactionError.self) {
            try tx.perform(on: file, retries: 0) { object in
                if !writeAttempted {
                    writeAttempted = true
                    try Data(#"{"version":2,"someoneElse":true}"#.utf8).write(to: file)
                }
                object["ours"] = true
            }
        }

        let onDisk = sandbox.readObject(file)
        #expect(onDisk["someoneElse"] as? Bool == true, "the other writer's change must survive")
        #expect(onDisk["ours"] == nil, "our change must not have been applied")
    }

    @Test("a transform that throws leaves the file untouched")
    func throwingTransformLeavesFileAlone() throws {
        let sandbox = try Sandbox()
        let file = try sandbox.file("settings.json", #"{"a":1}"#)
        let before = try Data(contentsOf: file)

        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try transaction(sandbox).perform(on: file) { object in
                object["b"] = 2
                throw Boom()
            }
        }
        #expect(try Data(contentsOf: file) == before)
    }
}

@Suite("Config transaction — idempotency")
struct ConfigTransactionIdempotencyTests {

    /// The shape a real hook installer uses: append if absent, never twice.
    private func addHook(to object: inout [String: Any], event: String, command: String) {
        var hooks = object["hooks"] as? [String: Any] ?? [:]
        var entries = hooks[event] as? [[String: Any]] ?? []
        guard !entries.contains(where: { ($0["command"] as? String) == command }) else { return }
        entries.append(["command": command, "timeout": 5])
        hooks[event] = entries
        object["hooks"] = hooks
    }

    @Test("applying the same edit twice does not duplicate anything")
    func idempotentAppend() throws {
        let sandbox = try Sandbox()
        let file = try sandbox.file("settings.json", "{}")
        let tx = transaction(sandbox)

        try tx.perform(on: file) { addHook(to: &$0, event: "Stop", command: "/bin/hook") }
        let second = try tx.perform(on: file) { addHook(to: &$0, event: "Stop", command: "/bin/hook") }

        #expect(!second.didChange, "the second configure must be a no-op")
        let hooks = sandbox.readObject(file)["hooks"] as? [String: Any]
        let entries = hooks?["Stop"] as? [[String: Any]]
        #expect(entries?.count == 1)
    }

    @Test("a different command is appended alongside the first")
    func distinctCommandsBothKept() throws {
        let sandbox = try Sandbox()
        let file = try sandbox.file("settings.json", "{}")
        let tx = transaction(sandbox)

        try tx.perform(on: file) { addHook(to: &$0, event: "Stop", command: "/bin/a") }
        try tx.perform(on: file) { addHook(to: &$0, event: "Stop", command: "/bin/b") }

        let hooks = sandbox.readObject(file)["hooks"] as? [String: Any]
        #expect((hooks?["Stop"] as? [[String: Any]])?.count == 2)
    }

    @Test("hooks the user wrote themselves are preserved")
    func userHooksPreserved() throws {
        let sandbox = try Sandbox()
        let file = try sandbox.file("settings.json", """
        {"hooks":{"Stop":[{"command":"/user/own/script.sh"}]}}
        """)
        let tx = transaction(sandbox)

        try tx.perform(on: file) { addHook(to: &$0, event: "Stop", command: "/bin/ours") }

        let hooks = sandbox.readObject(file)["hooks"] as? [String: Any]
        let commands = (hooks?["Stop"] as? [[String: Any]])?.compactMap { $0["command"] as? String }
        #expect(commands?.contains("/user/own/script.sh") == true)
        #expect(commands?.contains("/bin/ours") == true)
    }
}

@Suite("Config transaction — backup retention")
struct ConfigTransactionBackupTests {

    @Test("old backups are pruned to the configured limit")
    func backupsArePruned() throws {
        let sandbox = try Sandbox()
        let file = try sandbox.file("settings.json", "{}")
        let tx = ConfigTransaction(backupDirectory: sandbox.backups, maxBackups: 3)

        for index in 0..<8 {
            try tx.perform(on: file) { $0["n"] = index }
            // Distinct timestamps so backups sort unambiguously.
            try? FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(TimeInterval(index))],
                ofItemAtPath: file.path
            )
            Thread.sleep(forTimeInterval: 0.01)
        }

        let kept = (try? FileManager.default.contentsOfDirectory(
            at: sandbox.backups, includingPropertiesForKeys: nil
        )) ?? []
        #expect(kept.count <= 3, "backups grew unbounded: \(kept.count)")
    }

    @Test("a backup taken under a second file name survives the pruning it triggers")
    func pruningFollowsAgeNotTheFileName() throws {
        // The regression this exists for (2026-09-15): backups were pruned by
        // name, and a backup's name starts with the name of the file it came
        // from — so `agentpet.ts.<ts>` sorted before `settings.json.<ts>` no
        // matter how new it was. The moment a second integration wrote to this
        // directory, the backup taken during that very call was the first one
        // deleted, and the path the caller had just been handed was already
        // gone. Oh My Pi's extension is exactly that second integration.
        let sandbox = try Sandbox()
        let settings = try sandbox.file("settings.json", "{}")
        let extensionFile = try sandbox.file("agentpet.ts", "// one")
        let tx = ConfigTransaction(backupDirectory: sandbox.backups, maxBackups: 3)

        for index in 0..<4 {
            try tx.perform(on: settings) { $0["n"] = index }
            Thread.sleep(forTimeInterval: 0.02)
        }

        let outcome = try tx.perform(on: settings) { $0["n"] = 4 }
        // A backup of a non-JSON file goes through snapshot + backUp, which is
        // exactly what the extension configurator does.
        let backup = try #require(try tx.backUp(try tx.snapshot(extensionFile)))
        #expect(FileManager.default.fileExists(atPath: backup.path),
                "the backup this call reported was pruned by the same call")
        #expect(outcome.didChange)

        let kept = (try? FileManager.default.contentsOfDirectory(
            at: sandbox.backups, includingPropertiesForKeys: nil
        )) ?? []
        #expect(kept.count <= 3, "backups grew past the limit: \(kept.count)")
    }

    @Test("a backup directory that does not exist yet is created")
    func backupDirectoryCreated() throws {
        let sandbox = try Sandbox()
        let file = try sandbox.file("settings.json", #"{"a":1}"#)
        #expect(!FileManager.default.fileExists(atPath: sandbox.backups.path))

        try transaction(sandbox).perform(on: file) { $0["b"] = 2 }
        #expect(FileManager.default.fileExists(atPath: sandbox.backups.path))
    }
}

@Suite("Config transaction — durability")
struct ConfigTransactionDurabilityTests {

    @Test("the file is replaced atomically, never left partially written")
    func atomicReplacement() throws {
        let sandbox = try Sandbox()
        let file = try sandbox.file("settings.json", "{}")

        // A large value makes a non-atomic write observable as a truncated
        // file; an atomic one is never seen half-written.
        let big = String(repeating: "x", count: 500_000)
        try transaction(sandbox).perform(on: file) { $0["big"] = big }

        let contents = try Data(contentsOf: file)
        #expect((try? JSONSerialization.jsonObject(with: contents)) != nil)
        #expect(sandbox.readObject(file)["big"] as? String == big)
    }

    @Test("no temporary files are left behind")
    func noTemporaryFilesLeftBehind() throws {
        let sandbox = try Sandbox()
        let file = try sandbox.file("settings.json", "{}")
        try transaction(sandbox).perform(on: file) { $0["a"] = 1 }

        let entries = try FileManager.default.contentsOfDirectory(atPath: sandbox.root.path)
        let temporary = entries.filter { $0.contains("agentpet") && $0.hasSuffix(".tmp") }
        #expect(temporary.isEmpty, "left behind: \(temporary)")
    }

    @Test("existing file permissions are preserved")
    func permissionsPreserved() throws {
        let sandbox = try Sandbox()
        let file = try sandbox.file("settings.json", "{}")
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: file.path
        )

        try transaction(sandbox).perform(on: file) { $0["a"] = 1 }

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(mode == 0o600, "a private config file must not become world-readable")
    }

    @Test("a snapshot taken before an edit restores the exact original bytes")
    func rollbackIsByteExact() throws {
        let sandbox = try Sandbox()
        let original = """
        {
          "hooks" : {
            "Stop" : [ {"command":"/keep/me"} ]
          },
          "unrelated": [1, 2, 3]
        }
        """
        let file = try sandbox.file("settings.json", original)
        let before = try Data(contentsOf: file)
        let tx = transaction(sandbox)

        let snapshot = try tx.snapshot(file)
        try tx.perform(on: file) { $0["added"] = "by the runtime" }
        #expect(try Data(contentsOf: file) != before)

        try tx.rollback(to: snapshot)
        #expect(try Data(contentsOf: file) == before, "rollback must be byte-exact, format included")
    }
}
