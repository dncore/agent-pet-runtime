import Foundation

/// Maps one of an agent's hook event names onto a normalized kind.
///
/// Rules are evaluated in order and the first that applies wins, so a general
/// rule can be followed by narrower ones that override it.
public struct NormalizationRule: Codable, Sendable, Equatable {
    /// Hook event names this rule matches, e.g. `["PreToolUse", "PostToolUse"]`.
    public let matches: [String]
    public let kind: AgentEventKind
    /// Top-level payload key to read a human summary from, if present.
    public let summaryField: String?
    /// Top-level payload key holding a tool *name*.
    ///
    /// Tracked separately from `summary` because a summary may be the user's
    /// prompt — the `UserPromptSubmit` rule reads exactly that field — and the
    /// message panel draws a session's current tool beside the pet, over
    /// whatever the user is looking at. A name like `Bash` is a label; a
    /// prompt is not.
    public let toolNameField: String?
    /// Top-level payload key to read a second line from, if present.
    ///
    /// Used for Claude Code's `last_assistant_message` on `Stop` — the field
    /// exists precisely so hooks do not have to read and parse a transcript.
    /// It becomes the pet's "Ready" message, and it is never written to an
    /// event capture: it is model output, which is the one thing the log
    /// allowlist exists to keep out of files.
    public let detailField: String?
    /// Top-level payload key holding the session id.
    public let sessionIDField: String?
    /// Top-level payload key holding the working directory.
    public let workingDirectoryField: String?

    /// Only applies when the payload's notification type equals this.
    ///
    /// Claude Code reports several unrelated things through one `Notification`
    /// event, distinguished only by this field. Treating "a permission prompt"
    /// and "you have been idle a while" as the same state would leave the pet
    /// permanently asking for attention.
    public let whenNotificationType: String?

    /// Payload key the notification type is read from. `nil` means Claude
    /// Code's `notification_type`; Grok spells the same value
    /// `notificationType`.
    public let notificationTypeField: String?

    /// Only applies when the payload's `reason` equals this.
    ///
    /// Grok fires `Stop` twice per session: once with `reason: "end_turn"`
    /// when the turn ends, and once with `reason: "shutdown"` after the
    /// session's `SessionEnd`. Only the first is a turn ending — treating the
    /// second as one resurrects a session that has already closed.
    public let whenReason: String?

    /// Only applies when the payload's tool name equals this.
    ///
    /// Read from this rule's own `toolNameField` through the same reader the
    /// engine uses, so a nested path (`toolCall.name`, as Antigravity spells
    /// it) works here too. The same kind of condition as `whenReason`, one
    /// field over: an agent that reports *every* tool through a single event
    /// needs the payload's tool name to say which of them is the one that
    /// blocks on the user. Order matters as everywhere else — the narrow rule
    /// is written before the general one for the same event.
    public let whenToolName: String?

    /// Skips the rule when the payload lists a still-running background task.
    ///
    /// Claude Code fires `Stop` when the main agent yields, which happens while
    /// a background subagent is still working. Reporting that as a finished
    /// turn would make the pet announce completion in the middle of the job.
    public let suppressedByRunningBackgroundTask: Bool

    /// Payload key the background-task list is read from. `nil` means Claude
    /// Code's `background_tasks`; Grok sends `backgroundTasks`.
    public let backgroundTasksField: String?

    /// Skips the rule when the named top-level boolean is present and false.
    ///
    /// Antigravity's `Stop` carries `fullyIdle`: false means background
    /// commands or async tasks are still running, so the loop stopping is
    /// not the job stopping.
    public let suppressedWhenFalseField: String?

    /// Only applies when the named top-level field is a non-empty string.
    ///
    /// Antigravity always sends `error` on `Stop` but leaves it empty on a
    /// clean stop; presence alone distinguishes nothing, content does.
    public let requiresNonEmptyField: String?

    public init(
        matches: [String],
        kind: AgentEventKind,
        summaryField: String? = nil,
        detailField: String? = nil,
        toolNameField: String? = nil,
        sessionIDField: String? = nil,
        workingDirectoryField: String? = nil,
        whenNotificationType: String? = nil,
        notificationTypeField: String? = nil,
        whenReason: String? = nil,
        whenToolName: String? = nil,
        suppressedByRunningBackgroundTask: Bool = false,
        backgroundTasksField: String? = nil,
        suppressedWhenFalseField: String? = nil,
        requiresNonEmptyField: String? = nil
    ) {
        self.matches = matches
        self.kind = kind
        self.summaryField = summaryField
        self.detailField = detailField
        self.toolNameField = toolNameField
        self.sessionIDField = sessionIDField
        self.workingDirectoryField = workingDirectoryField
        self.whenNotificationType = whenNotificationType
        self.notificationTypeField = notificationTypeField
        self.whenReason = whenReason
        self.whenToolName = whenToolName
        self.suppressedByRunningBackgroundTask = suppressedByRunningBackgroundTask
        self.backgroundTasksField = backgroundTasksField
        self.suppressedWhenFalseField = suppressedWhenFalseField
        self.requiresNonEmptyField = requiresNonEmptyField
    }
}

/// Everything agent-specific about turning hook events into `AgentEvent`s.
///
/// This is data, not code, on purpose: the design requires that adding an agent
/// does not mean modifying the runtime core, and the differences between agents
/// really are just "which names, which keys".
public struct AgentProfile: Codable, Sendable, Equatable {
    public let agentID: String
    public let displayName: String
    public let rules: [NormalizationRule]
    /// Used when the payload carries no session id — a terminal-only agent
    /// still has to be trackable.
    public let fallbackSessionID: String
    /// Confidence to attach to events from this profile. Process-observation
    /// profiles set this lower than hook-based ones.
    public let confidence: ConfidenceLevel

    public init(
        agentID: String,
        displayName: String,
        rules: [NormalizationRule],
        fallbackSessionID: String = "default",
        confidence: ConfidenceLevel = .high
    ) {
        self.agentID = agentID
        self.displayName = displayName
        self.rules = rules
        self.fallbackSessionID = fallbackSessionID
        self.confidence = confidence
    }
}

public enum NormalizationError: Error, Equatable, Sendable {
    case unknownEvent(String, agentID: String)
    case notJSON
}

public extension NormalizationRule {
    /// Whether this rule is the right one for an event, given its payload.
    func applies(to eventName: String, payload: [String: Any]) -> Bool {
        guard matches.contains(eventName) else { return false }

        if let required = whenNotificationType {
            let actual = payload[notificationTypeField ?? "notification_type"] as? String
            guard actual == required else { return false }
        }

        if let required = whenReason {
            let actual = payload["reason"] as? String
            guard actual == required else { return false }
        }

        if let required = whenToolName {
            // Through the shared reader, not `payload[field]`: it resolves
            // dotted paths and the first entry of a string array, which is how
            // an agent whose tool name is nested spells it.
            //
            // No field to read it from means the condition cannot be met, so
            // the rule does not apply — rather than silently matching every
            // payload, which would turn a typed mistake into a wrong state.
            guard let field = toolNameField,
                  EventNormalizer.string(payload, field) == required else { return false }
        }

        if suppressedByRunningBackgroundTask,
           EventNormalizer.hasRunningBackgroundTask(
               payload, field: backgroundTasksField ?? "background_tasks"
           ) {
            return false
        }

        if let field = suppressedWhenFalseField,
           let flag = payload[field] as? Bool, flag == false {
            return false
        }

        if let field = requiresNonEmptyField {
            guard let value = payload[field] as? String, !value.isEmpty else { return false }
        }

        return true
    }
}

/// Turns a `BridgeEnvelope` into zero or more `AgentEvent`s.
public struct EventNormalizer: Sendable {
    private let profiles: [String: AgentProfile]

    public init(profiles: [AgentProfile]) {
        self.profiles = Dictionary(uniqueKeysWithValues: profiles.map { ($0.agentID, $0) })
    }

    public func profile(for agentID: String) -> AgentProfile? {
        profiles[agentID]
    }

    /// An envelope from an unknown agent, or naming an event no rule covers,
    /// yields an empty array. Unrecognised input is not an error worth
    /// crashing over — a newer agent version may simply have added an event.
    public func normalize(_ envelope: BridgeEnvelope) -> [AgentEvent] {
        guard let profile = profiles[envelope.agentID] else { return [] }

        let payload = Self.parseObject(envelope.rawPayload)
        guard let rule = profile.rules.first(where: {
            $0.applies(to: envelope.eventName, payload: payload)
        }) else {
            return []
        }

        let sessionID = Self.string(payload, rule.sessionIDField)
            ?? Self.fallbackSessionID(for: envelope, profile: profile)
        let summary = Self.string(payload, rule.summaryField)
        let detail = Self.string(payload, rule.detailField)
            .flatMap { PetNotification.preview(of: $0) }
        let toolName = Self.string(payload, rule.toolNameField)
        let cwd = Self.string(payload, rule.workingDirectoryField)

        var focus: FocusTarget = .unavailable
        if let cwd, !cwd.isEmpty {
            focus = .openingDirectory(URL(fileURLWithPath: cwd))
        }

        // A status-line reading is the one event that describes rather than
        // moves: it carries what the session's own status line knows (tokens
        // used, its name, its project) and no state at all.
        let context = rule.kind == .contextUpdate
            ? SessionContext.fromStatusPayload(payload, at: envelope.receivedAt)
            : nil
        if rule.kind == .contextUpdate, context == nil {
            // A reading with nothing in it — a session before its first
            // message reports nulls — is not worth an activity.
            return []
        }

        return [AgentEvent(
            agentID: envelope.agentID,
            sessionID: sessionID,
            kind: rule.kind,
            at: envelope.receivedAt,
            confidence: EventConfidence(
                level: profile.confidence,
                source: "\(envelope.agentID).hook.\(envelope.eventName)"
            ),
            summary: summary,
            detail: detail,
            toolName: toolName,
            projectPath: cwd.map { URL(fileURLWithPath: $0) },
            focusTarget: focus,
            context: context
        )]
    }

    /// Whether the payload lists a background task that has not finished.
    ///
    /// Claude Code's `Stop` fires whenever the main agent yields, which it does
    /// while a background subagent is still working. Without this check every
    /// long job is announced as complete the moment the agent first pauses.
    static func hasRunningBackgroundTask(
        _ payload: [String: Any],
        field: String = "background_tasks"
    ) -> Bool {
        guard let tasks = payload[field] as? [[String: Any]] else { return false }
        return tasks.contains { task in
            (task["status"] as? String)?.lowercased() == "running"
        }
    }

    /// What to call a session when the payload does not name one.
    ///
    /// The shim's parent process is the agent, so its pid distinguishes
    /// concurrent sessions of the same agent. Falling back to a constant would
    /// merge every session into one indistinguishable activity, which is worse
    /// than a slightly awkward name.
    static func fallbackSessionID(for envelope: BridgeEnvelope, profile: AgentProfile) -> String {
        if let ppid = envelope.proc?.ppid, ppid > 0 {
            return "ppid-\(ppid)"
        }
        return profile.fallbackSessionID
    }

    /// The payload is parsed leniently and only for a few top-level keys. A
    /// payload that is not JSON at all is legitimate — some hooks pass plain
    /// text — and must not fail the event.
    static func parseObject(_ data: Data) -> [String: Any] {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    /// Reads one top-level key, a dotted path (`toolCall.name`), or — for an
    /// array of strings like Antigravity's `workspacePaths` — its first entry.
    /// Anything else has no single answer and reads as absent.
    static func string(_ payload: [String: Any], _ key: String?) -> String? {
        guard let key, !key.isEmpty else { return nil }

        var value: Any? = payload
        for part in key.split(separator: ".") {
            guard let dictionary = value as? [String: Any] else { return nil }
            value = dictionary[String(part)]
        }

        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let strings = value as? [String] { return strings.first }
        return nil
    }
}
