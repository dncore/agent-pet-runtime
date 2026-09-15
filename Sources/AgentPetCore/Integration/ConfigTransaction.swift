import Foundation

/// A point-in-time copy of a configuration file, including enough information
/// to detect that someone else changed it in the meantime.
public struct ConfigSnapshot: Sendable, Equatable {
    public let url: URL
    /// False when the file did not exist; rolling back then means deleting it.
    public let existed: Bool
    public let contents: Data
    /// SHA-256 of `contents`.
    public let fingerprint: String
    public let modificationDate: Date?

    public var byteCount: Int { contents.count }
}

public enum ConfigTransactionError: Error, Equatable, Sendable {
    /// The file changed between snapshot and write. Not an error the user
    /// caused; the caller retries against fresh state.
    case concurrentModification(path: String)
    case unreadable(path: String, detail: String)
    /// Existing content is not valid JSON. Refusing beats clobbering a file we
    /// do not understand — it may be mid-edit, or a format we have not seen.
    case existingContentNotJSON(path: String, detail: String)
    case writeFailed(path: String, detail: String)
    case rollbackFailed(path: String, detail: String)
    case validationFailed(path: String, detail: String)
    /// Could not obtain a clean snapshot within the retry budget.
    case gaveUpAfterRetries(attempts: Int)
}

public struct TransactionOutcome: Sendable, Equatable {
    public let snapshot: ConfigSnapshot
    public let backupURL: URL?
    public let didChange: Bool
    public let attempts: Int
}

/// Safely edits a JSON configuration file that other software also owns.
///
/// The danger this exists to contain: `~/.claude/settings.json` is written by
/// Claude Code itself, and a malformed version of it can break the user's
/// entire agent. So every change is
/// `snapshot → back up → modify in memory → re-check → atomic write → verify`,
/// and any failure restores the previous bytes.
///
/// The transform is applied to an in-memory copy and the result written in one
/// step. Incremental editing of the real file would leave it half-written if
/// anything failed partway.
public struct ConfigTransaction: Sendable {

    public let backupDirectory: URL
    public let maxBackups: Int

    public init(backupDirectory: URL, maxBackups: Int = 10) {
        self.backupDirectory = backupDirectory
        self.maxBackups = maxBackups
    }

    // MARK: - Reading

    public func snapshot(_ url: URL) throws -> ConfigSnapshot {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: url.path) else {
            return ConfigSnapshot(
                url: url,
                existed: false,
                contents: Data(),
                fingerprint: Hashing.sha256(Data()),
                modificationDate: nil
            )
        }

        let contents: Data
        do {
            contents = try Data(contentsOf: url)
        } catch {
            throw ConfigTransactionError.unreadable(path: url.path, detail: "\(error)")
        }

        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return ConfigSnapshot(
            url: url,
            existed: true,
            contents: contents,
            fingerprint: Hashing.sha256(contents),
            modificationDate: attributes?[.modificationDate] as? Date
        )
    }

    // MARK: - Editing

    /// Applies `transform` to the file, rolling back if anything goes wrong.
    ///
    /// `transform` receives the parsed object and mutates it in place. It
    /// should be idempotent: it will be handed already-edited content on a
    /// retry, and running it twice must not append a second copy of anything.
    @discardableResult
    public func perform(
        on url: URL,
        retries: Int = 2,
        transform: (inout [String: Any]) throws -> Void
    ) throws -> TransactionOutcome {

        var lastError: Error = ConfigTransactionError.gaveUpAfterRetries(attempts: 0)

        for attempt in 1...(retries + 1) {
            do {
                return try attemptOnce(url: url, attempt: attempt, transform: transform)
            } catch let error as ConfigTransactionError {
                // Only a concurrent edit is worth retrying: the fix is to
                // start over from what is now on disk.
                guard case .concurrentModification = error else { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    private func attemptOnce(
        url: URL,
        attempt: Int,
        transform: (inout [String: Any]) throws -> Void
    ) throws -> TransactionOutcome {

        let original = try snapshot(url)

        // An unparseable file is refused rather than overwritten.
        var object: [String: Any] = [:]
        if original.existed, !original.contents.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: original.contents) else {
                throw ConfigTransactionError.existingContentNotJSON(
                    path: url.path, detail: "content is not valid JSON"
                )
            }
            guard let dictionary = parsed as? [String: Any] else {
                throw ConfigTransactionError.existingContentNotJSON(
                    path: url.path, detail: "top level is not a JSON object"
                )
            }
            object = dictionary
        }

        let before = NSDictionary(dictionary: object)
        try transform(&object)

        // Idempotency is judged on meaning, not bytes. Serialising reformats
        // the whole file, so a byte comparison would report a change on every
        // run and rewrite the user's config for nothing.
        if NSDictionary(dictionary: object).isEqual(before) {
            let wouldCreateEmptyFile = !original.existed && object.isEmpty
            if !wouldCreateEmptyFile {
                return TransactionOutcome(
                    snapshot: original, backupURL: nil, didChange: false, attempts: attempt
                )
            }
        }

        let newContents: Data
        do {
            newContents = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw ConfigTransactionError.writeFailed(path: url.path, detail: "\(error)")
        }

        // Re-read immediately before writing. The gap between the first read
        // and here is where another process could have written.
        let current = try snapshot(url)
        guard current.fingerprint == original.fingerprint else {
            throw ConfigTransactionError.concurrentModification(path: url.path)
        }

        let backup = try original.existed ? backUp(original) : nil

        do {
            try writeAtomically(newContents, to: url)
        } catch {
            throw ConfigTransactionError.writeFailed(path: url.path, detail: "\(error)")
        }

        // Read back and prove the result parses and is what we intended.
        do {
            try verify(url: url, expecting: newContents)
        } catch {
            // The file on disk is now unusable; put back exactly what was
            // there, or remove it if there was nothing.
            try restore(original)
            throw ConfigTransactionError.validationFailed(
                path: url.path,
                detail: "written content failed verification, previous state restored"
            )
        }

        let written = try snapshot(url)
        return TransactionOutcome(
            snapshot: written, backupURL: backup, didChange: true, attempts: attempt
        )
    }

    // MARK: - Editing text files

    /// Applies `transform` to a file that is not JSON — Grok's `config.toml` —
    /// with the same discipline the JSON path uses: snapshot, re-check the
    /// fingerprint, back up, write atomically, verify, and restore on failure.
    ///
    /// There is no TOML parser here on purpose. The caller edits lines and
    /// `verify` gets the last word on whether the result is acceptable;
    /// anything it rejects is rolled back byte for byte, so a file this app
    /// cannot fully parse is still never left damaged.
    @discardableResult
    public func performText(
        on url: URL,
        retries: Int = 2,
        transform: (inout String) throws -> Void,
        verify: (String) -> Bool
    ) throws -> TransactionOutcome {
        var lastError: Error = ConfigTransactionError.gaveUpAfterRetries(attempts: 0)

        for attempt in 1...(retries + 1) {
            do {
                return try attemptTextOnce(
                    url: url, attempt: attempt, transform: transform, verify: verify
                )
            } catch let error as ConfigTransactionError {
                // Only a concurrent edit is worth retrying: the fix is to
                // start over from what is now on disk.
                guard case .concurrentModification = error else { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    private func attemptTextOnce(
        url: URL,
        attempt: Int,
        transform: (inout String) throws -> Void,
        verify: (String) -> Bool
    ) throws -> TransactionOutcome {

        let original = try snapshot(url)
        guard let originalText = String(data: original.contents, encoding: .utf8) else {
            throw ConfigTransactionError.unreadable(path: url.path, detail: "not valid UTF-8")
        }

        var text = originalText
        try transform(&text)

        if text == originalText {
            return TransactionOutcome(
                snapshot: original, backupURL: nil, didChange: false, attempts: attempt
            )
        }

        // The caller's own judgement of the result, before anything is written.
        guard verify(text) else {
            throw ConfigTransactionError.validationFailed(
                path: url.path, detail: "the edit failed its own verification"
            )
        }

        let newContents = Data(text.utf8)

        // Re-read immediately before writing. The gap between the first read
        // and here is where another process could have written.
        let current = try snapshot(url)
        guard current.fingerprint == original.fingerprint else {
            throw ConfigTransactionError.concurrentModification(path: url.path)
        }

        let backup = try original.existed ? backUp(original) : nil

        do {
            try writeAtomically(newContents, to: url)
        } catch {
            throw ConfigTransactionError.writeFailed(path: url.path, detail: "\(error)")
        }

        do {
            let onDisk = try Data(contentsOf: url)
            guard onDisk == newContents else {
                throw ConfigTransactionError.validationFailed(
                    path: url.path, detail: "file on disk does not match what was written"
                )
            }
        } catch {
            // The file on disk is now unusable; put back exactly what was
            // there, or remove it if there was nothing.
            try? restore(original)
            throw ConfigTransactionError.validationFailed(
                path: url.path,
                detail: "written content failed verification, previous state restored"
            )
        }

        let written = try snapshot(url)
        return TransactionOutcome(
            snapshot: written, backupURL: backup, didChange: true, attempts: attempt
        )
    }

    // MARK: - Rollback

    /// Restores a file to a snapshot, byte for byte.
    public func rollback(to snapshot: ConfigSnapshot) throws {
        do {
            try restore(snapshot)
        } catch {
            throw ConfigTransactionError.rollbackFailed(
                path: snapshot.url.path, detail: "\(error)"
            )
        }
    }

    private func restore(_ snapshot: ConfigSnapshot) throws {
        if snapshot.existed {
            try writeAtomically(snapshot.contents, to: snapshot.url)
        } else {
            // The file did not exist before us, so leaving an empty object
            // behind would be a change we invented.
            if FileManager.default.fileExists(atPath: snapshot.url.path) {
                try FileManager.default.removeItem(at: snapshot.url)
            }
        }
    }

    // MARK: - Filesystem

    /// A write that either happens completely or not at all.
    ///
    /// `rename(2)` within a directory is atomic, so a reader sees either the
    /// old file or the new one — never a half-written one.
    func writeAtomically(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Underscore-prefixed so it does not look like one of the agent's own
        // config files if something goes wrong mid-write.
        let temporary = directory.appendingPathComponent("._agentpet-\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)

        // Preserve the original permissions; a settings file that suddenly
        // became world-readable would be worse than the edit itself.
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let permissions = attributes[.posixPermissions] as? NSNumber {
            try? FileManager.default.setAttributes(
                [.posixPermissions: permissions], ofItemAtPath: temporary.path
            )
        }

        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func verify(url: URL, expecting contents: Data) throws {
        let onDisk = try Data(contentsOf: url)
        guard onDisk == contents else {
            throw ConfigTransactionError.validationFailed(
                path: url.path, detail: "file on disk does not match what was written"
            )
        }
        guard (try? JSONSerialization.jsonObject(with: onDisk)) != nil else {
            throw ConfigTransactionError.validationFailed(
                path: url.path, detail: "written file is not valid JSON"
            )
        }
    }

    /// Not private: the extension-file configurators back a file up through
    /// the same directory and the same naming, so one retention policy covers
    /// every edit the runtime makes.
    func backUp(_ snapshot: ConfigSnapshot) throws -> URL? {
        guard snapshot.existed else { return nil }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        let name = "\(snapshot.url.lastPathComponent).\(Int(Date().timeIntervalSince1970)).\(snapshot.fingerprint.prefix(8))"
        let target = backupDirectory.appendingPathComponent(name)

        do {
            try snapshot.contents.write(to: target, options: .atomic)
        } catch {
            // A failed backup must abort the edit: proceeding without one
            // would leave nothing to restore.
            throw ConfigTransactionError.writeFailed(
                path: target.path, detail: "could not back up: \(error)"
            )
        }

        pruneBackups()
        return target
    }

    /// Keeps backup growth bounded, oldest first.
    ///
    /// Age comes from the filesystem, not from the name. The name is
    /// `"<file>.<timestamp>.<fingerprint>"`, so sorting names *is*
    /// chronological — but only while every backup here came from the same
    /// file. A second file name in this directory breaks that: `agentpet.json.…`
    /// sorts before `settings.json.…` however new it is, so the backup taken
    /// during a call is the first one deleted, and the path the caller was
    /// just handed no longer exists (2026-09-15 — the backup directory is
    /// multi-source the moment a second integration writes into it; ported
    /// from PR #1 by CaffreySun).
    private func pruneBackups() {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: backupDirectory, includingPropertiesForKeys: Array(keys)
        ) else { return }
        guard entries.count > maxBackups else { return }

        func age(_ url: URL) -> Date? {
            (try? url.resourceValues(forKeys: keys))?.contentModificationDate
        }

        let ordered = entries.sorted { left, right in
            switch (age(left), age(right)) {
            case let (leftDate?, rightDate?):
                // Two writes inside the same clock tick are still distinct
                // files; the name settles the order the clock cannot.
                return leftDate == rightDate
                    ? left.lastPathComponent < right.lastPathComponent
                    : leftDate < rightDate
            case (_?, nil):  return true
            case (nil, _?):  return false
            case (nil, nil): return left.lastPathComponent < right.lastPathComponent
            }
        }

        for url in ordered.prefix(ordered.count - maxBackups) {
            try? fileManager.removeItem(at: url)
        }
    }
}
