import Foundation

/// The shipped agent profiles.
///
/// Confidence differs by mechanism and is not cosmetic: a hook reports what
/// actually happened, while process observation only suggests it. Sending both
/// at `.high` would let a guess masquerade as a fact in the UI.
public enum AgentProfiles {

    /// Claude Code hooks.
    ///
    /// The event set below is the complete list the installed build (2.1.268)
    /// dispatches. Payloads carry `session_id`, `cwd`, `tool_name`,
    /// `notification_type`, and `background_tasks`; hooks run synchronously
    /// with the payload on stdin.
    ///
    /// The state mapping follows what the events actually mean rather than
    /// what their names suggest:
    ///
    /// - `PermissionRequest` — and `Notification` carrying
    ///   `notification_type: permission_prompt` — is the *only* signal that the
    ///   agent is genuinely blocked. It is the one state worth holding.
    /// - `Notification` is a grab bag: it also carries `idle_prompt`,
    ///   `auth_success`, and `elicitation_dialog`. Treating all of them as
    ///   "waiting for input" is what leaves the pet permanently asking for
    ///   attention once more than one session is open.
    /// - `Stop` fires at the end of *every* turn, not at the end of a session.
    ///   It means the agent has gone quiet, which is `idle`.
    /// - `TaskCompleted` is the event that means a task actually finished.
    public static let claudeCode = AgentProfile(
        agentID: "claude-code",
        displayName: "Claude Code",
        rules: [
            // --- Blocked on the user: the only sticky attention state. ---

            NormalizationRule(
                matches: ["PermissionRequest"],
                kind: .waitingApproval,
                summaryField: "tool_name",
                toolNameField: "tool_name",
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            // Older builds route the same signal through Notification.
            NormalizationRule(
                matches: ["Notification"],
                kind: .waitingApproval,
                summaryField: "message",
                toolNameField: "tool_name",
                sessionIDField: "session_id",
                workingDirectoryField: "cwd",
                whenNotificationType: "permission_prompt"
            ),

            // --- Working. ---

            NormalizationRule(
                matches: ["UserPromptSubmit"],
                kind: .working,
                summaryField: "prompt",
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            NormalizationRule(
                matches: ["PreToolUse"],
                kind: .working,
                summaryField: "tool_name",
                toolNameField: "tool_name",
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            NormalizationRule(
                matches: ["PostToolUse"],
                kind: .working,
                summaryField: "tool_name",
                toolNameField: "tool_name",
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            // A subagent starting or finishing does not end the session: the
            // main agent carries on, so both mean still-working.
            NormalizationRule(
                matches: ["SubagentStart", "SubagentStop"],
                kind: .working,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            NormalizationRule(
                matches: ["PreCompact"],
                kind: .working,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            NormalizationRule(
                matches: ["PostCompact"],
                kind: .working,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),

            // --- Finished. ---

            // A whole task finished: the one worth celebrating.
            NormalizationRule(
                matches: ["TaskCompleted"],
                kind: .completed,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            // The turn ended. This fires constantly, so it settles to idle —
            // unless a background subagent is still running, in which case the
            // agent has only paused and is still working.
            //
            // `last_assistant_message` rides along as the second line of the
            // pet's "Ready" message, the way Codex shows a preview of what the
            // agent just said. Claude Code supplies that field on `Stop`
            // specifically so hooks do not have to read the transcript.
            NormalizationRule(
                matches: ["Stop"],
                kind: .completed,
                detailField: "last_assistant_message",
                sessionIDField: "session_id",
                workingDirectoryField: "cwd",
                suppressedByRunningBackgroundTask: true
            ),
            NormalizationRule(
                matches: ["Stop"],
                kind: .working,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),

            // --- Failure. ---

            NormalizationRule(
                matches: ["StopFailure"],
                kind: .failed,
                summaryField: "error",
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),

            // --- Lifecycle. ---

            NormalizationRule(
                matches: ["SessionStart"],
                kind: .sessionStarted,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            NormalizationRule(
                matches: ["SessionEnd"],
                kind: .sessionClosed,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),

            // --- Description, not state. ---

            // Arrives only when the status-line tap is installed (see
            // StatusLineTap): Claude Code runs the status-line command with
            // its own JSON, the shim reduces it to this handful of fields, and
            // the session id is the same one the hooks use. It tells the panel
            // how full a context window is and what the session is called —
            // facts hooks never carry — and deliberately changes no state.
            NormalizationRule(
                matches: ["Statusline"],
                kind: .contextUpdate,
                sessionIDField: "session_id"
            ),

            // Deliberately absent: `Notification` carrying `idle_prompt`,
            // `auth_success`, or `elicitation_dialog`, and `TeammateIdle`.
            //
            // None of them is a state the pet should show. `idle_prompt` in
            // particular only says the agent has been quiet a while, which
            // `Stop` already reported — and mapping it to a state that never
            // expires is precisely what left the pet stuck asking for attention
            // whenever more than one session was open.
            //
            // An event with no matching rule changes nothing.
        ]
    )

    /// Grok's event names match Claude Code's and its core fields carry
    /// Claude-style snake_case aliases (`session_id`, `hook_event_name`,
    /// `tool_name`), but the turn-end body and the background-task list are
    /// camelCase only, and `Stop` fires once per turn and again at shutdown.
    /// Field names and the `reason` filter below come from payloads captured
    /// off the wire (2026-09-15); see docs/ARCHITECTURE.md §6.7b.
    public static let grok = AgentProfile(
        agentID: "grok",
        displayName: "Grok",
        rules: [
            // --- Blocked on the user. ---

            // The payload uses the camelCase spelling; the snake_case rule
            // behind it keeps working if a future build aliases the field.
            NormalizationRule(
                matches: ["Notification"],
                kind: .waitingApproval,
                summaryField: "message",
                sessionIDField: "session_id",
                workingDirectoryField: "cwd",
                whenNotificationType: "permission_prompt",
                notificationTypeField: "notificationType"
            ),
            NormalizationRule(
                matches: ["Notification"],
                kind: .waitingApproval,
                summaryField: "message",
                sessionIDField: "session_id",
                workingDirectoryField: "cwd",
                whenNotificationType: "permission_prompt"
            ),

            // --- Working. ---

            NormalizationRule(
                matches: ["UserPromptSubmit"],
                kind: .working,
                summaryField: "prompt",
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            NormalizationRule(
                matches: ["PreToolUse", "PostToolUse"],
                kind: .working,
                summaryField: "toolName",
                toolNameField: "toolName",
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            // A failing tool does not end the turn, and neither does a
            // subagent starting or finishing.
            NormalizationRule(
                matches: ["PostToolUseFailure", "SubagentStart", "SubagentStop", "PreCompact", "PostCompact"],
                kind: .working,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),

            // --- Finished. ---

            // Only `end_turn` is a turn ending. The shutdown fire arrives
            // after `SessionEnd`; mapping it would resurrect a session that
            // has already closed. `lastAssistantMessage` is the pet's "Ready"
            // line, the counterpart of Claude's `last_assistant_message`.
            NormalizationRule(
                matches: ["Stop"],
                kind: .completed,
                detailField: "lastAssistantMessage",
                sessionIDField: "session_id",
                workingDirectoryField: "cwd",
                whenReason: "end_turn",
                suppressedByRunningBackgroundTask: true,
                backgroundTasksField: "backgroundTasks"
            ),
            // The suppressed case: the main agent yielded while a background
            // subagent is still running, which is still work.
            NormalizationRule(
                matches: ["Stop"],
                kind: .working,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd",
                whenReason: "end_turn"
            ),
            // An interrupt is a finished turn too — the user stopped it, and
            // a session left "working" for the five-minute stale timeout
            // reads as asleep. Known edge: Grok dispatches cancel reports off
            // the command loop, so one can land after the next prompt's
            // `UserPromptSubmit` and briefly show completed over working.
            NormalizationRule(
                matches: ["StopCancelled"],
                kind: .completed,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),

            // --- Failure. ---

            NormalizationRule(
                matches: ["StopFailure"],
                kind: .failed,
                summaryField: "error",
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),

            // --- Lifecycle. ---

            NormalizationRule(
                matches: ["SessionStart"],
                kind: .sessionStarted,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            NormalizationRule(
                matches: ["SessionEnd"],
                kind: .sessionClosed,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),

            // --- Description, not state. ---

            // Arrives only when the status-line tap is installed: Grok runs
            // the command with its own JSON, the shim reduces it to the same
            // handful of fields it keeps for Claude, and the session id is
            // the one the hooks use.
            NormalizationRule(
                matches: ["Statusline"],
                kind: .contextUpdate,
                sessionIDField: "session_id"
            ),
        ],
        fallbackSessionID: "grok-default"
    )

    /// Codex reports through its own hooks — stable since 0.124 and shipped
    /// in the installed 0.153.4, where `codex features list` shows `hooks`
    /// stable. The config is `~/.codex/hooks.json` (JSON, Claude-shaped) and
    /// the payload is Claude-shaped too: the binary's wire structs carry
    /// `session_id`, `hook_event_name`, `model`, `permission_mode`, and the
    /// `tool_*` fields (verified 2026-09-15). Two differences from Claude
    /// Code: an interrupted turn reports `Interrupt` instead of `Stop`, and
    /// there is no `Notification`, `TaskCompleted`, or `StopFailure`.
    ///
    /// Codex skips untrusted hooks silently until the user reviews them in
    /// its `/hooks` panel. That gate is the user's, not ours; when events do
    /// arrive they are hook-grade.
    public static let codex = AgentProfile(
        agentID: "codex",
        displayName: "Codex",
        rules: [
            // --- Blocked on the user. ---

            NormalizationRule(
                matches: ["PermissionRequest"],
                kind: .waitingApproval,
                summaryField: "tool_name",
                toolNameField: "tool_name",
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),

            // --- Working. ---

            NormalizationRule(
                matches: ["UserPromptSubmit"],
                kind: .working,
                summaryField: "prompt",
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            NormalizationRule(
                matches: ["PreToolUse", "PostToolUse"],
                kind: .working,
                summaryField: "tool_name",
                toolNameField: "tool_name",
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            NormalizationRule(
                matches: ["SubagentStart", "SubagentStop", "PreCompact", "PostCompact"],
                kind: .working,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),

            // --- Finished. ---

            // `last_assistant_message` is what Claude Code carries; Codex
            // does not promise it, so the preview appears only when the
            // field is there.
            NormalizationRule(
                matches: ["Stop"],
                kind: .completed,
                detailField: "last_assistant_message",
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            // An interrupt is a finished turn too — the user stopped it, and
            // a session left "working" for the five-minute stale timeout
            // reads as asleep.
            NormalizationRule(
                matches: ["Interrupt"],
                kind: .completed,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),

            // --- Lifecycle. ---

            NormalizationRule(
                matches: ["SessionStart"],
                kind: .sessionStarted,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            NormalizationRule(
                matches: ["SessionEnd"],
                kind: .sessionClosed,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
        ],
        fallbackSessionID: "codex-default"
    )

    /// Pi reports through the runtime's own extension
    /// (`~/.pi/agent/extensions/agentpet.ts`, installed by `PiConfigurator`):
    /// it forwards lifecycle events, and at each settle a context reading in
    /// the same reduced shape the status-line taps deliver.
    ///
    /// `agent_settled` — not `agent_end` — is the moment to settle on: after
    /// `agent_end` Pi may still auto-retry, auto-compact, or run queued
    /// follow-ups, so only the settle means the turn is really over.
    public static let pi = AgentProfile(
        agentID: "pi",
        displayName: "Pi",
        rules: [
            NormalizationRule(
                matches: ["session_start"],
                kind: .sessionStarted,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            NormalizationRule(
                matches: ["agent_start", "tool_execution_start"],
                kind: .working,
                summaryField: "toolName",
                toolNameField: "toolName",
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            // Pi raises these while one of its own UI prompts (a permission
            // gate, a picker) is on screen — the one "it is waiting for you"
            // signal the extension can draw from.
            NormalizationRule(
                matches: ["ui_prompt_start"],
                kind: .waitingInput,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            NormalizationRule(
                matches: ["agent_settled"],
                kind: .completed,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            NormalizationRule(
                matches: ["session_shutdown"],
                kind: .sessionClosed,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            NormalizationRule(
                matches: ["context_update"],
                kind: .contextUpdate,
                sessionIDField: "session_id"
            ),
        ]
    )

    /// Antigravity reports through the CLI's own `hooks.json` (named hooks),
    /// and this profile is written against payloads captured off the real
    /// 1.2.3 wire (2026-09-15; fixtures in `Tests/.../Fixtures/antigravity/`).
    ///
    /// What the capture settled, against the docs: payloads are protojson
    /// camelCase; `SessionStart` fires although the published event table
    /// does not list it; `PostToolUse` is registered but never fired in any
    /// captured turn, so the working signal leans on `PreToolUse` and the
    /// per-model-call `Pre/PostInvocation`; `Stop` carries `terminationReason`
    /// (observed `NO_TOOL_CALL`, not the docs' `model_stop`), `fullyIdle`, and
    /// an `error` string that is present but empty on a clean stop. There is
    /// no waiting-for-input event to map.
    public static let antigravity = AgentProfile(
        agentID: "antigravity",
        displayName: "Antigravity",
        rules: [
            // --- Working. ---

            NormalizationRule(
                matches: ["PreInvocation", "PostInvocation"],
                kind: .working,
                sessionIDField: "conversationId",
                workingDirectoryField: "workspacePaths"
            ),
            NormalizationRule(
                matches: ["PreToolUse", "PostToolUse"],
                kind: .working,
                summaryField: "toolCall.name",
                toolNameField: "toolCall.name",
                sessionIDField: "conversationId",
                workingDirectoryField: "workspacePaths"
            ),

            // --- Finished. ---

            // An error stop is a failure; a clean stop with work still in
            // flight is still working; anything else is a finished turn.
            NormalizationRule(
                matches: ["Stop"],
                kind: .failed,
                summaryField: "error",
                sessionIDField: "conversationId",
                workingDirectoryField: "workspacePaths",
                requiresNonEmptyField: "error"
            ),
            NormalizationRule(
                matches: ["Stop"],
                kind: .completed,
                detailField: "finalModelOutput",
                sessionIDField: "conversationId",
                workingDirectoryField: "workspacePaths",
                suppressedWhenFalseField: "fullyIdle"
            ),
            NormalizationRule(
                matches: ["Stop"],
                kind: .working,
                sessionIDField: "conversationId",
                workingDirectoryField: "workspacePaths"
            ),

            // --- Lifecycle. ---

            // Undocumented but real: the hook fires, with the common fields
            // only (captured 2026-09-15). `SessionEnd` is registered but was
            // not observed on a headless exit; it stays mapped for the TUI.
            NormalizationRule(
                matches: ["SessionStart"],
                kind: .sessionStarted,
                sessionIDField: "conversationId",
                workingDirectoryField: "workspacePaths"
            ),
            NormalizationRule(
                matches: ["SessionEnd"],
                kind: .sessionClosed,
                sessionIDField: "conversationId",
                workingDirectoryField: "workspacePaths"
            ),

            // --- Description, not state. ---

            NormalizationRule(
                matches: ["Statusline"],
                kind: .contextUpdate,
                sessionIDField: "session_id"
            ),
        ],
        fallbackSessionID: "antigravity-default"
    )

    /// Oh My Pi reports through the extension the manager installs into
    /// `~/.omp/agent/extensions/`, which spawns the shim once per event with a
    /// payload of its own making — `session_id`, `cwd`, and a `toolName` where
    /// one applies. Nothing else is read, so the event names below are the
    /// extension's, not omp's.
    ///
    /// The mapping against the installed build (18.1.22) is:
    ///
    /// - `tool_approval_requested` is omp's approval gate — the one signal
    ///   that a tool is held up waiting for the user, and the counterpart of
    ///   Claude Code's `PermissionRequest`.
    /// - `tool_execution_start` carrying `ask` is the other: omp's `ask` tool
    ///   is a question put to the user, and the session cannot proceed until
    ///   it is answered. Every other tool is just work.
    /// - `agent_end` fires once per prompt, and means a turn is over —
    ///   *unless* the payload says `willContinue`, which the session sets when
    ///   it has already scheduled a retry. The extension drops those rather
    ///   than reporting a settle that never happened.
    /// - `tool_execution_end` keeps a long tool call from looking idle and is
    ///   what clears an `ask` wait once the answer lands.
    /// - Deliberately absent: `turn_start`/`turn_end` (omp's turn is one model
    ///   call, not one prompt, so both would mean "still working" at best),
    ///   `message_*`, and the session-tree events. `session_start` is mapped
    ///   for the same reason Claude Code's is: it refreshes a session that is
    ///   already known, and one that has only announced itself never becomes a
    ///   row at all — the engine drops a lone `session_start` for every agent
    ///   (the pre-warmed-session rule), not just this one.
    public static let ohMyPi = AgentProfile(
        agentID: "omp",
        displayName: "Oh My Pi",
        rules: [
            // --- Blocked on the user: the only sticky attention state. ---

            // The `ask` tool is a question, so it is matched before the
            // general tool rule below.
            NormalizationRule(
                matches: ["tool_execution_start"],
                kind: .waitingInput,
                summaryField: "toolName",
                toolNameField: "toolName",
                sessionIDField: "session_id",
                workingDirectoryField: "cwd",
                whenToolName: "ask"
            ),
            NormalizationRule(
                matches: ["tool_approval_requested"],
                kind: .waitingApproval,
                summaryField: "toolName",
                toolNameField: "toolName",
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),

            // --- Working. ---

            NormalizationRule(
                matches: ["agent_start"],
                kind: .working,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            NormalizationRule(
                matches: ["tool_execution_start"],
                kind: .working,
                summaryField: "toolName",
                toolNameField: "toolName",
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            // The answer to an `ask` arrives as the end of that tool call, so
            // this is what takes the pet off "Needs input" while the agent
            // carries on with what it was told.
            NormalizationRule(
                matches: ["tool_execution_end", "tool_approval_resolved"],
                kind: .working,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),

            // --- Finished. ---

            NormalizationRule(
                matches: ["agent_end"],
                kind: .completed,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),

            // --- Lifecycle. ---

            NormalizationRule(
                matches: ["session_start"],
                kind: .sessionStarted,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            NormalizationRule(
                matches: ["session_shutdown"],
                kind: .sessionClosed,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),

            // The reduced reading the extension sends at each settle — session
            // id, model, how full the context window is. It describes a
            // session rather than moving it, like the status-line taps.
            NormalizationRule(
                matches: ["context_update"],
                kind: .contextUpdate,
                sessionIDField: "session_id"
            ),
        ]
    )

    /// Fallback for anything reached by process observation alone.
    public static let genericCLI = AgentProfile(
        agentID: "generic-cli",
        displayName: "Generic CLI",
        rules: [
            NormalizationRule(matches: ["process-started"], kind: .sessionStarted),
            NormalizationRule(matches: ["process-active"], kind: .working),
            NormalizationRule(matches: ["process-idle"], kind: .waitingInput),
            NormalizationRule(matches: ["process-exited"], kind: .sessionClosed),
        ],
        fallbackSessionID: "generic-default",
        confidence: .low
    )

    public static let all: [AgentProfile] = [claudeCode, grok, codex, pi, antigravity, ohMyPi, genericCLI]

    public static func profile(for agentID: String) -> AgentProfile? {
        all.first { $0.agentID == agentID }
    }
}
