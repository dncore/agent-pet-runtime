import Foundation

public enum ConfigurationError: Error, Equatable, Sendable {
    case unknownAgent(String)
    case noConfigurationTarget(String)
    case transactionFailed(String)
    /// A file the runtime would have to replace or delete exists, but was not
    /// written by it. Carries the path. Refusing beats clobbering somebody
    /// else's file — see `ExtensionFileConfigurator`.
    case foreignFile(String)
}

public struct ConfigurationOutcome: Sendable, Equatable {
    public let record: IntegrationRecord
    /// Files that actually changed. Empty means the call was a no-op.
    public let changedFiles: [String]
    public let backupURLs: [String]

    public var didChange: Bool { !changedFiles.isEmpty }
}

/// Installs and removes the hook lines that let an agent reach the bridge.
///
/// Record-driven and stateless: everything needed to undo an install travels
/// in the `IntegrationRecord`, so uninstall works even if the runtime has since
/// moved to a different path.
public protocol AgentConfigurator: Sendable {
    var agentID: String { get }

    /// Configuration files this configurator would touch. Used for inspection.
    func configurationTargets() -> [URL]

    /// Whether the recorded entries are actually present in the files.
    func entriesPresent(in record: IntegrationRecord) -> Bool

    /// Installs hooks, given an optional previous record to replace.
    /// Must be idempotent: running it twice must not duplicate anything.
    func configure(shimPath: String, replacing previous: IntegrationRecord?, now: Date) throws -> ConfigurationOutcome

    /// Removes exactly the entries in the record, leaving everything else.
    func uninstall(_ record: IntegrationRecord, now: Date) throws -> ConfigurationOutcome
}

/// Shared implementation for agents whose hook configuration is a JSON object
/// shaped `hooks.<Event>: [{ matcher, hooks: [{ type, command, timeout }] }]`.
///
/// Claude Code uses this shape, and Grok documents its schema as matching it.
/// Keeping one implementation means adding a similarly-shaped agent is a
/// configuration entry, not new code.
public struct JSONHookConfigurator: AgentConfigurator {

    public let agentID: String
    public let configURL: URL
    /// Hook events to install.
    public let events: [String]
    public let timeoutSeconds: Int
    private let transaction: ConfigTransaction

    public init(
        agentID: String,
        configURL: URL,
        events: [String],
        transaction: ConfigTransaction,
        timeoutSeconds: Int = 5
    ) {
        self.agentID = agentID
        self.configURL = configURL
        self.events = events
        self.transaction = transaction
        self.timeoutSeconds = timeoutSeconds
    }

    public func configurationTargets() -> [URL] { [configURL] }

    public static func command(shimPath: String, agentID: String, event: String) -> String {
        "\(shellQuoted(shimPath)) --agent \(agentID) --event \(event)"
    }

    /// Matches the shell quoting hook setup uses, so the same path produces
    /// the same string in both places and idempotency holds across them.
    private static func shellQuoted(_ path: String) -> String {
        HookSetup.shellQuoted(path)
    }

    // MARK: - Reading

    /// Every command currently registered for our events, whoever wrote it.
    public func existingCommands() -> [String: [String]] {
        guard let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any]
        else { return [:] }

        var result: [String: [String]] = [:]
        for (event, value) in hooks {
            let entries = value as? [[String: Any]] ?? []
            let commands = entries.flatMap { entry -> [String] in
                (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
            }
            // Flat form: the event maps straight to a list of hook objects.
            let flat = entries.compactMap { $0["command"] as? String }
            result[event] = commands + flat
        }
        return result
    }

    public func entriesPresent(in record: IntegrationRecord) -> Bool {
        let present = existingCommands()
        return record.entries.allSatisfy { entry in
            present[entry.event]?.contains(entry.command) == true
        }
    }

    // MARK: - Configure

    public func configure(
        shimPath: String,
        replacing previous: IntegrationRecord?,
        now: Date
    ) throws -> ConfigurationOutcome {

        var entries: [WrittenEntry] = []
        var changedFiles: [String] = []
        var backups: [String] = []

        // Remove any stale entries first so a moved shim does not leave the
        // old path behind calling a binary that is no longer there.
        let staleCommands = Set(
            (previous?.entries ?? [])
                .filter { $0.command != Self.command(shimPath: shimPath, agentID: agentID, event: $0.event) }
                .map(\.command)
        )

        let outcome = try transaction.perform(on: configURL) { object in
            var hooks = object["hooks"] as? [String: Any] ?? [:]

            for event in events {
                var hookEntries = hooks[event] as? [[String: Any]] ?? []

                if !staleCommands.isEmpty {
                    hookEntries = hookEntries.compactMap { entry in
                        var entry = entry
                        var inner = entry["hooks"] as? [[String: Any]] ?? []
                        inner.removeAll { staleCommands.contains($0["command"] as? String ?? "") }
                        // An entry whose inner hooks we removed entirely was ours.
                        if inner.isEmpty && entry["hooks"] != nil { return nil }
                        entry["hooks"] = inner
                        return entry
                    }
                }

                let command = Self.command(shimPath: shimPath, agentID: agentID, event: event)
                let alreadyThere = hookEntries.contains { entry in
                    (entry["hooks"] as? [[String: Any]] ?? [])
                        .contains { $0["command"] as? String == command }
                }
                if !alreadyThere {
                    hookEntries.append([
                        "matcher": "*",
                        "hooks": [[
                            "type": "command",
                            "command": command,
                            "timeout": timeoutSeconds,
                        ]],
                    ])
                }
                hooks[event] = hookEntries
                entries.append(WrittenEntry(file: configURL.path, event: event, command: command))
            }

            object["hooks"] = hooks
        }

        if outcome.didChange { changedFiles.append(configURL.path) }
        if let backup = outcome.backupURL { backups.append(backup.path) }

        let record = IntegrationRecord(
            agentID: agentID,
            status: .configured,
            configuredAt: previous?.configuredAt ?? now,
            lastValidatedAt: now,
            shimPath: shimPath,
            entries: entries
        )
        return ConfigurationOutcome(record: record, changedFiles: changedFiles, backupURLs: backups)
    }

    // MARK: - Uninstall

    public func uninstall(_ record: IntegrationRecord, now: Date) throws -> ConfigurationOutcome {
        // Match only on what we recorded. Anything else in the file belongs to
        // the user, or to another tool, and is not ours to remove.
        let ours = Set(record.entries.map(\.command))

        var removed: [WrittenEntry] = []
        let outcome = try transaction.perform(on: configURL) { object in
            guard var hooks = object["hooks"] as? [String: Any] else { return }

            for (event, value) in hooks {
                guard var entries = value as? [[String: Any]] else { continue }
                let before = entries.count

                entries = entries.compactMap { entry in
                    var entry = entry
                    var inner = entry["hooks"] as? [[String: Any]] ?? []
                    let originalInner = inner
                    inner.removeAll { ours.contains($0["command"] as? String ?? "") }

                    if inner.isEmpty && !originalInner.isEmpty {
                        // The whole entry was ours.
                        return nil
                    }
                    entry["hooks"] = inner
                    return entry
                }

                if entries.count != before {
                    removed.append(contentsOf: record.entries.filter { $0.event == event })
                }

                // Leaving `"PreToolUse": []` behind would be residue we
                // invented: the key did not exist before, and an empty hook
                // list means nothing to the agent.
                if entries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = entries
                }
            }

            // Same reasoning one level up.
            if hooks.isEmpty {
                object.removeValue(forKey: "hooks")
            } else {
                object["hooks"] = hooks
            }
        }

        var changedFiles: [String] = []
        var backups: [String] = []
        if outcome.didChange { changedFiles.append(configURL.path) }
        if let backup = outcome.backupURL { backups.append(backup.path) }

        let updated = IntegrationRecord(
            agentID: agentID,
            status: .notConfigured,
            configuredAt: record.configuredAt,
            lastValidatedAt: now,
            shimPath: record.shimPath,
            entries: []
        )
        return ConfigurationOutcome(record: updated, changedFiles: changedFiles, backupURLs: backups)
    }
}
