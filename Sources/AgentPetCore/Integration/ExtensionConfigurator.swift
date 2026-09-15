import Foundation

/// The extension file the runtime installs into an agent that is extended by
/// dropping one file into a directory, rather than by editing a table in a
/// configuration file.
///
/// Oh My Pi is the first of these: it loads every `*.ts` in
/// `~/.omp/agent/extensions/` at session start, so the integration is a file
/// rather than an edit — which makes install a write and removal a delete, and
/// makes "did we write this?" a question about the file's own contents.
///
/// Generated in code rather than shipped as a resource, for the same reason
/// `HookSetup` assembles Claude Code's hooks in code: the exact text can be
/// asserted in tests and read without installing anything.
public enum AgentPetExtension {

    /// The name the runtime installs under. One file per extension, so the
    /// name *is* the identity — a second copy would be a second extension.
    public static let fileName = "agentpet.ts"

    /// A line present in every file the runtime writes, and therefore the only
    /// evidence it accepts that such a file is its own before replacing it.
    /// Removal asks a different question — whether the file still carries the
    /// `// shim:` line the *record* holds — so a file that lost that line is
    /// left alone even though this marker still identifies it. Stable across
    /// versions on purpose: the shim line below moves when the app does, and a
    /// file written by an older build still has to be recognisable as ours.
    public static let ownershipMarker = "// agentpet-runtime extension"

    /// The line naming the shim and the agent this copy reports to.
    ///
    /// Recorded verbatim in the `IntegrationRecord`, so removal matches on
    /// content rather than on a rule — the same contract the hook lines have,
    /// and what lets an install made by a since-moved runtime still be
    /// recognised (and replaced) later.
    public static func markerLine(agentID: String, shimPath: String) -> String {
        // Through the same transformation the generated comment uses, or this
        // record would stop matching the file it was written for.
        "// shim: \(ExtensionTemplate.commentSafe(shimPath)) --agent \(agentID)"
    }

    /// Whether a file's text is one of ours.
    public static func owns(_ text: String) -> Bool {
        text.contains(ownershipMarker)
    }

    /// Every event the installed extension listens for.
    ///
    /// Kept here — rather than only inside the generated source — so a test can
    /// prove the two agree, and that the normalizer has a rule for each of
    /// them. An event with no rule would be a process spawned per occurrence
    /// for a state change that cannot happen.
    public static let listenedEvents: [String] = [
        "session_start",
        "agent_start",
        "tool_execution_start",
        "tool_execution_end",
        "tool_approval_requested",
        "tool_approval_resolved",
        "agent_end",
        "session_shutdown",
    ]

    /// Every event the extension actually reports, which is one more than it
    /// listens for: the context reading rides out of the settle handler rather
    /// than off an event of its own.
    public static let reportedEvents = listenedEvents + ["context_update"]



    /// The extension's source for this agent, through the template both
    /// extension-file integrations share (`ExtensionTemplate`); `PiConfigurator`
    /// enters it at `.pi`.
    ///
    /// Every handler reports and returns nothing:
    /// omp runs extension handlers in-process, `tool_call` handlers fail
    /// *closed* (a throw blocks the tool), and a pet that changed what the
    /// agent does would be a far worse bug than one that misses an event. So
    /// no handler here is registered for an event that can block, the two
    /// registrations that do have a cost are called out in the file itself,
    /// and every step is wrapped so a failure cannot reach the agent.
    public static func source(agentID: String, shimPath: String) -> String {
        ExtensionTemplate.source(
            agentID: agentID,
            shimPath: shimPath,
            events: .ohMyPi,
            marker: "\(ownershipMarker) — installed by Agent Pet Runtime."
        )
    }

    /// A JavaScript string literal, escaped rather than interpolated.
    ///
    /// Paths are the only thing here that comes from outside, and a path can
    /// legally contain a quote or a backslash. Building the literal by
    /// concatenation is how a path with an apostrophe silently breaks a
    /// generated file; escaping is how it does not.
    static func jsStringLiteral(_ value: String) -> String {
        ExtensionTemplate.jsStringLiteral(value)
    }
}

/// Installs the runtime's extension for agents whose integration is one file
/// in an extensions directory.
///
/// The JSON transaction cannot do this — its whole job is editing a table
/// inside a file somebody else owns, and this file is *ours*, whole. What it
/// keeps is the discipline: snapshot, back up before changing anything,
/// write atomically, read back and prove the result, and never touch a file
/// that is not ours.
public struct ExtensionFileConfigurator: AgentConfigurator {

    public let agentID: String
    /// The directory the agent scans, e.g. `~/.omp/agent/extensions`.
    public let directory: URL
    public let fileName: String
    private let transaction: ConfigTransaction

    public init(
        agentID: String,
        directory: URL,
        fileName: String = AgentPetExtension.fileName,
        transaction: ConfigTransaction
    ) {
        self.agentID = agentID
        self.directory = directory
        self.fileName = fileName
        self.transaction = transaction
    }

    public var fileURL: URL { directory.appendingPathComponent(fileName) }

    public func configurationTargets() -> [URL] { [fileURL] }

    /// True when the file exists and still carries every line the record says
    /// the runtime wrote into it — the shim line included, so a file whose
    /// marker line was rewritten (by hand, or by a later Configure with a
    /// different shim path) is reported as disconnected until Configure runs
    /// again. A moved app is deliberately *not* one of these cases: nothing
    /// compares the path in the record with the path in use, and the record and
    /// the file are written together, so they agree until something rewrites
    /// one of them.
    public func entriesPresent(in record: IntegrationRecord) -> Bool {
        guard !record.entries.isEmpty else { return false }
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return false }
        return record.entries.allSatisfy { text.contains($0.command) }
    }

    public func configure(
        shimPath: String,
        replacing previous: IntegrationRecord?,
        now: Date
    ) throws -> ConfigurationOutcome {

        let source = AgentPetExtension.source(agentID: agentID, shimPath: shimPath)
        let entry = WrittenEntry(
            file: fileURL.path,
            event: fileName,
            command: AgentPetExtension.markerLine(agentID: agentID, shimPath: shimPath)
        )

        let record = IntegrationRecord(
            agentID: agentID,
            status: .configured,
            configuredAt: previous?.configuredAt ?? now,
            lastValidatedAt: now,
            shimPath: shimPath,
            entries: [entry]
        )

        // A file we did not write is somebody's extension — and one we cannot
        // even read as text certainly is: `String(decoding:)` substitutes
        // replacement characters for anything that is not UTF-8, so a marker
        // cannot survive the trip and this refuses it either way.
        if let data = try? Data(contentsOf: fileURL),
           !AgentPetExtension.owns(String(decoding: data, as: UTF8.self)) {
            throw ConfigurationError.foreignFile(fileURL.path)
        }

        // The same text transaction the other extension integration uses:
        // snapshot, back up, write atomically, read back, and restore on any
        // failure. It also decides idempotency, so a second Configure with the
        // same shim path changes nothing at all, not even a rewrite.
        let outcome = try transaction.performText(
            on: fileURL,
            transform: { text in text = source },
            verify: {
                AgentPetExtension.owns($0)
                    && $0.contains(AgentPetExtension.jsStringLiteral(shimPath))
            }
        )

        return ConfigurationOutcome(
            record: record,
            changedFiles: outcome.didChange ? [fileURL.path] : [],
            backupURLs: outcome.backupURL.map { [$0.path] } ?? []
        )
    }

    public func uninstall(_ record: IntegrationRecord, now: Date) throws -> ConfigurationOutcome {
        let updated = IntegrationRecord(
            agentID: agentID,
            status: .notConfigured,
            configuredAt: record.configuredAt,
            lastValidatedAt: now,
            shimPath: record.shimPath,
            entries: []
        )

        let snapshot = try transaction.snapshot(fileURL)
        guard snapshot.existed,
              let text = String(data: snapshot.contents, encoding: .utf8),
              !record.entries.isEmpty,
              record.entries.allSatisfy({ text.contains($0.command) })
        else {
            // Already gone, or replaced by hand: there is nothing of ours left
            // to remove, and that is not a failure.
            return ConfigurationOutcome(record: updated, changedFiles: [], backupURLs: [])
        }

        // Kept even though the file is ours: a backup is what makes deleting a
        // file reversible, and the user may have added to it since.
        var backups: [String] = []
        if let backup = try transaction.backUp(snapshot) { backups.append(backup.path) }

        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            throw ConfigurationError.transactionFailed(
                "could not remove \(fileURL.path): \(error)"
            )
        }

        // The directory itself is left alone: the agent scans it, an empty
        // extensions directory means "no extensions", and it may predate us.
        return ConfigurationOutcome(record: updated, changedFiles: [fileURL.path], backupURLs: backups)
    }
}
