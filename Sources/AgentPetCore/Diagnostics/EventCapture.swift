import Foundation

/// Records what an agent actually sent, for diagnosing why the pet reacted
/// wrongly.
///
/// Off unless explicitly enabled, and deliberately lossy. A Claude Code hook
/// payload carries far more than the state machine needs: alongside
/// `tool_name` it carries `tool_input` and `tool_response`, which are the
/// arguments an agent passed and whatever came back — command text, file
/// contents, and command output.
///
/// This project's own rules say prompts, model output, and source code are
/// never recorded. A capture that dumped whole payloads would break that
/// promise for the sake of convenience, so unknown keys are dropped rather
/// than copied and a future agent field cannot leak into a log by default.
public enum EventCapture {

    /// Payload keys a capture record may contain.
    ///
    /// Each is here because some diagnosis needs it. Anything whose value is
    /// user content is not, however useful it might be for debugging.
    ///
    /// Two spellings of the same two facts, because two agents name them
    /// differently: Claude Code's hooks send `session_id` / `tool_name`, while
    /// the in-process extensions send the camelCase names their own API uses
    /// (`sessionId` / `toolName` — Pi's extension uses the camelCase tool name
    /// next to the snake-case session id today). Missing a spelling is not
    /// cosmetic: an event spooled without its session id replays as a second
    /// row under a process-derived name, beside the real one. The list stays
    /// hand-written rather than derived from the profiles — a profile's
    /// `summaryField` is the user's own prompt on `UserPromptSubmit`, and an
    /// allowlist that followed profiles would follow prompts onto disk.
    public static let capturableKeys: Set<String> = [
        "session_id",       // opaque id; tells concurrent sessions apart
        "sessionId",        // the same, as the in-process extensions spell it
        "hook_event_name",
        "tool_name",        // "Bash", "Read" — a label, not content
        "toolName",         // the same, as the in-process extensions spell it
        "notification_type",
        "permission_mode",
        "cwd",
        "background_tasks",
        "error",
    ]

    /// Sentinels explaining an omission, so a reader is not left guessing
    /// whether a field was absent or removed.
    static let omittedKeysField = "_omitted_keys"
    static let unparsedField = "_unparsed_bytes"

    /// Reduces a payload to the keys above.
    ///
    /// `background_tasks` is flattened to type and status: the array otherwise
    /// carries each task's own prompt and output.
    public static func sanitizedPayload(_ data: Data) -> [String: Any] {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // Not JSON, or empty. Record only the size — a payload that could
            // not be parsed is exactly the case where dumping it would be
            // tempting and is exactly the case not to.
            return [unparsedField: data.count]
        }

        var kept: [String: Any] = [:]
        for key in capturableKeys {
            guard let value = object[key] else { continue }

            if key == "background_tasks", let tasks = value as? [[String: Any]] {
                kept[key] = tasks.map { task in
                    ["type": task["type"] as? String ?? "?",
                     "status": task["status"] as? String ?? "?"]
                }
            } else if let nested = value as? [String: Any] {
                // A dictionary whose contents we have not reasoned about could
                // hold anything; keep only its key names.
                kept[key] = nested.keys.sorted()
            } else {
                kept[key] = value
            }
        }

        let dropped = Set(object.keys).subtracting(capturableKeys)
        if !dropped.isEmpty {
            kept[omittedKeysField] = dropped.sorted()
        }
        return kept
    }

    /// One record for an event, safe to write to disk.
    public static func record(for envelope: BridgeEnvelope) -> [String: Any] {
        [
            "agentID": envelope.agentID,
            "eventName": envelope.eventName,
            "receivedAt": ISO8601DateFormatter().string(from: envelope.receivedAt),
            "ppid": Int(envelope.proc?.ppid ?? 0),
            "tty": envelope.proc?.tty ?? "",
            "payload": sanitizedPayload(envelope.rawPayload),
        ]
    }

    /// How large a capture may grow before it is rotated out of the way.
    ///
    /// `--log-events` is a switch a user may leave on for a day; without a
    /// ceiling the file grows until the disk notices. One previous file is
    /// kept (`<path>.1`), so the capture is bounded at twice this and the
    /// events from just before the rotation are still readable.
    public static let maximumCaptureBytes = 8 * 1024 * 1024

    /// Appends one JSON line, creating the file owner-only.
    ///
    /// An event log records what the user's agents were doing, so it is not
    /// something other accounts on the machine should be able to read. The
    /// default umask would leave it world-readable, and a file that predates
    /// this rule is tightened on every append.
    /// Moves the capture aside once it has reached its ceiling.
    ///
    /// Renamed rather than truncated: a log that silently emptied itself is
    /// worse than a large one, and the file that was rotated out is where the
    /// answer to "what happened just before" lives.
    @discardableResult
    static func rotateIfNeeded(
        _ url: URL,
        appending bytes: Int,
        maximumBytes: Int,
        fileManager: FileManager
    ) -> Bool {
        guard let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
              size.intValue + bytes > maximumBytes
        else { return false }

        let previous = url.appendingPathExtension("1")
        try? fileManager.removeItem(at: previous)
        try? fileManager.moveItem(at: url, to: previous)
        return true
    }

    /// Creates the capture with its first line, owner-only.
    private static func create(_ url: URL, with data: Data, fileManager: FileManager) {
        fileManager.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        )
    }

    public static func append(_ record: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: record),
              let line = String(data: data, encoding: .utf8)
        else { return }

        append(Data((line + "\n").utf8), to: url)
    }

    public static func append(
        _ data: Data,
        to url: URL,
        maximumBytes: Int = EventCapture.maximumCaptureBytes
    ) {
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: url.path) {
            create(url, with: data, fileManager: fileManager)
            return
        }

        if rotateIfNeeded(url, appending: data.count, maximumBytes: maximumBytes, fileManager: fileManager) {
            // The file this line was going into has just been moved aside, so
            // the line starts the next one. Skipping this is how a rotation
            // used to eat exactly the event that caused it.
            create(url, with: data, fileManager: fileManager)
            return
        }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
