import Foundation

/// Installs the Pi integration: one small TypeScript extension the runtime
/// owns, dropped into Pi's auto-discovered extensions directory.
///
/// Pi extensions run with the user's full permissions, so the file is written
/// plainly — readable, marked at the top, and self-contained (node built-ins
/// only, no package install, no settings edit). Uninstall deletes exactly that
/// file, and only while it still carries the marker; anything the user wrote
/// is refused rather than overwritten.
public struct PiConfigurator: AgentConfigurator {

    public let agentID = "pi"

    /// Recognises the runtime's own file. The version suffix lets a future
    /// install replace the previous copy by content rather than by trust.
    public static let marker = "// agentpet-extension v1"

    public let extensionURL: URL

    private let transaction: ConfigTransaction
    private let backupDirectory: URL

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        transaction: ConfigTransaction
    ) {
        self.extensionURL = home.appendingPathComponent(".pi/agent/extensions/agentpet.ts")
        self.transaction = transaction
        self.backupDirectory = transaction.backupDirectory
    }

    public func configurationTargets() -> [URL] { [extensionURL] }

    // MARK: - Template

    /// The path as it appears inside the template's JavaScript string literal.
    static func jsStringLiteral(_ path: String) -> String {
        ExtensionTemplate.jsStringLiteral(path)
    }

    /// The generated file is shared with Oh My Pi's integration — one template,
    /// with the event set and the ownership marker as its parameters
    /// (`ExtensionTemplate`).
    public static func template(shimPath: String) -> String {
        ExtensionTemplate.source(
            agentID: "pi",
            shimPath: shimPath,
            events: .pi,
            marker: "\(marker) — installed by Agent Pet Runtime."
        )
    }


    // MARK: - Reading

    public func entriesPresent(in record: IntegrationRecord) -> Bool {
        guard let shimPath = record.shimPath,
              let data = try? Data(contentsOf: extensionURL),
              let text = String(data: data, encoding: .utf8)
        else { return false }
        return text.contains(Self.marker)
            && text.contains(Self.jsStringLiteral(shimPath))
    }

    // MARK: - Configure

    public func configure(
        shimPath: String,
        replacing previous: IntegrationRecord?,
        now: Date
    ) throws -> ConfigurationOutcome {

        // A file that is not ours is refused, never overwritten — an
        // extension is code, and code that runs with the user's permissions
        // is not something to replace on a guess.
        if let data = try? Data(contentsOf: extensionURL),
           let existing = String(data: data, encoding: .utf8),
           !existing.contains(Self.marker) {
            throw ConfigurationError.transactionFailed(
                "\(extensionURL.path) exists and is not the runtime's file; "
                    + "move it aside first if you want the runtime to install its own."
            )
        }

        let template = Self.template(shimPath: shimPath)
        let outcome = try transaction.performText(
            on: extensionURL,
            transform: { text in text = template },
            verify: { $0.contains(Self.marker) && $0.contains(Self.jsStringLiteral(shimPath)) }
        )

        let record = IntegrationRecord(
            agentID: agentID,
            status: .configured,
            configuredAt: previous?.configuredAt ?? now,
            lastValidatedAt: now,
            shimPath: shimPath,
            entries: [WrittenEntry(file: extensionURL.path, event: "extension", command: Self.marker)]
        )

        return ConfigurationOutcome(
            record: record,
            changedFiles: outcome.didChange ? [extensionURL.path] : [],
            backupURLs: outcome.backupURL.map { [$0.path] } ?? []
        )
    }

    // MARK: - Uninstall

    public func uninstall(
        _ record: IntegrationRecord,
        now: Date
    ) throws -> ConfigurationOutcome {
        var changed = false
        var backups: [String] = []

        if let data = try? Data(contentsOf: extensionURL),
           let text = String(data: data, encoding: .utf8),
           text.contains(Self.marker) {
            // Backed up before the delete, the same as every other edit here.
            try FileManager.default.createDirectory(
                at: backupDirectory, withIntermediateDirectories: true
            )
            let backup = backupDirectory.appendingPathComponent(
                "\(extensionURL.lastPathComponent)."
                    + "\(Int(Date().timeIntervalSince1970)).\(Hashing.sha256(data).prefix(8))"
            )
            try data.write(to: backup, options: .atomic)
            backups.append(backup.path)
            try FileManager.default.removeItem(at: extensionURL)
            changed = true
        }

        let updated = IntegrationRecord(
            agentID: agentID,
            status: .notConfigured,
            configuredAt: record.configuredAt,
            lastValidatedAt: now,
            shimPath: record.shimPath,
            entries: []
        )
        return ConfigurationOutcome(
            record: updated,
            changedFiles: changed ? [extensionURL.path] : [],
            backupURLs: backups
        )
    }
}
