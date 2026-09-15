import Foundation

/// The known agents, and how each one is detected and configured.
///
/// One entry per agent. Adding an agent means adding a case here; nothing in
/// the activity engine, renderer, or bridge changes.
public struct AgentIntegrationProfile: Sendable {
    public let agentID: String
    public let displayName: String
    public let detection: AgentDetector.Specification
    /// `nil` when the agent has no configuration surface we can safely write.
    /// The UI shows it as detectable but not configurable.
    public let configurator: (any AgentConfigurator)?
    public let capabilities: Set<IntegrationCapability>
    /// What the runtime's integration *is* for this agent, so the wording on
    /// every surface can match it. A user told to check "the hooks in the
    /// config file" when their integration is a single file in a directory
    /// would go looking for something that does not exist.
    public let mechanism: IntegrationMechanism
    /// Why there is no configurator, in the words that fit this agent.
    ///
    /// No agent lacks a configurator today (2026-09-15), but the field stays:
    /// the next agent whose surface cannot be written safely needs somewhere
    /// to say so. Shown on the card and by `--configure`.
    public let configurationNote: String?

    /// The one thing the user still has to do after configuring, if any.
    ///
    /// Codex skips hooks until they are reviewed and trusted in its own
    /// `/hooks` panel, so writing the file is not the last step there.
    /// Shown by `--configure` and in the manager's status line.
    public let postConfigureHint: String?

    public init(
        agentID: String,
        displayName: String,
        detection: AgentDetector.Specification,
        configurator: (any AgentConfigurator)?,
        capabilities: Set<IntegrationCapability>,
        mechanism: IntegrationMechanism = .hookTable,
        configurationNote: String? = nil,
        postConfigureHint: String? = nil
    ) {
        self.agentID = agentID
        self.displayName = displayName
        self.detection = detection
        self.configurator = configurator
        self.capabilities = capabilities
        self.mechanism = mechanism
        self.configurationNote = configurationNote
        self.postConfigureHint = postConfigureHint
    }
}

/// How the runtime installs itself into an agent.
public enum IntegrationMechanism: String, Codable, Sendable, Equatable {
    /// Lines inside a configuration file the agent owns and writes itself —
    /// Claude Code's `hooks` table, and Grok's. Installing means editing
    /// somebody else's file, so it is transactional; removing means deleting
    /// exactly the lines that were recorded.
    case hookTable
    /// One file the runtime owns outright, in a directory the agent scans —
    /// Pi's and Oh My Pi's extensions. Installing is a write, removing is a
    /// delete, and the file is only touched while it still identifies itself as
    /// ours.
    case extensionFile
}

public enum IntegrationCapability: String, Codable, Sendable, CaseIterable {
    case detect
    case configure
    case uninstall
    case liveEvents
    case testEvent
    /// v0.1 cannot reliably raise another app's window; see docs/SPEC-REVIEW.md §3.3.
    case focusSession
}

public enum AgentIntegrationRegistry {

    public static func home() -> URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Claude Code reads hooks from its user settings file. Its hook payloads
    /// carry session id and cwd, so events correlate properly.
    public static func claudeCode(transaction: ConfigTransaction) -> AgentIntegrationProfile {
        let settings = home().appendingPathComponent(".claude/settings.json")
        return AgentIntegrationProfile(
            agentID: "claude-code",
            displayName: "Claude Code",
            detection: .init(
                agentID: "claude-code",
                displayName: "Claude Code",
                executableNames: ["claude"],
                extraSearchPaths: [home().appendingPathComponent(".local/bin")],
                configFiles: [settings]
            ),
            configurator: JSONHookConfigurator(
                agentID: "claude-code",
                configURL: settings,
                events: HookSetup.claudeCodeEvents,
                transaction: transaction
            ),
            capabilities: [.detect, .configure, .uninstall, .liveEvents, .testEvent]
        )
    }

    /// Grok's hooks live in `~/.grok/hooks/` as JSON (its config.toml can
    /// carry `[[hooks.<Event>]]` as an alternative). The configurator writes
    /// one dedicated file there and flips Grok's Claude-compat scan off in
    /// `config.toml`, so Grok is the only source of its own events; see
    /// docs/ARCHITECTURE.md §6.7b.
    public static func grok(transaction: ConfigTransaction) -> AgentIntegrationProfile {
        let config = home().appendingPathComponent(".grok/config.toml")
        return AgentIntegrationProfile(
            agentID: "grok",
            displayName: "Grok",
            detection: .init(
                agentID: "grok",
                displayName: "Grok",
                executableNames: ["grok"],
                configFiles: [config]
            ),
            configurator: GrokConfigurator(transaction: transaction),
            capabilities: [.detect, .configure, .uninstall, .liveEvents, .testEvent]
        )
    }

    /// Codex's hooks are stable and live in `~/.codex/hooks.json` as
    /// Claude-shaped JSON, so the same configurator Claude uses applies: it
    /// merges around other tools' entries (Otty already owns four on this
    /// machine) and removes only its own. Every non-managed entry must then
    /// be reviewed and trusted by hand in Codex's `/hooks` panel — that is
    /// the user's step, and the hint says so.
    public static func codex(transaction: ConfigTransaction) -> AgentIntegrationProfile {
        let config = home().appendingPathComponent(".codex/hooks.json")
        return AgentIntegrationProfile(
            agentID: "codex",
            displayName: "Codex",
            detection: .init(
                agentID: "codex",
                displayName: "Codex",
                executableNames: ["codex"],
                configFiles: [config]
            ),
            configurator: JSONHookConfigurator(
                agentID: "codex",
                configURL: config,
                events: codexHookEvents,
                transaction: transaction
            ),
            capabilities: [.detect, .configure, .uninstall, .liveEvents, .testEvent],
            postConfigureHint: "Codex skips hooks until they are trusted: open Codex and "
                + "run /hooks to review and trust them once."
        )
    }

    /// Every event the Codex profile has a rule for, and only those.
    /// `Notification`, `TaskCompleted`, and `StopFailure` are Claude Code's;
    /// Codex never fires them.
    public static let codexHookEvents = [
        "SessionStart", "SessionEnd", "UserPromptSubmit",
        "PreToolUse", "PostToolUse", "PermissionRequest",
        "PreCompact", "PostCompact", "SubagentStart", "SubagentStop",
        "Stop", "Interrupt",
    ]

    /// Pi is extended by one TypeScript file in `~/.pi/agent/extensions/`;
    /// the configurator writes exactly that file (node built-ins only, no
    /// package install, no settings edit) and deletes it on removal; see
    /// docs/ARCHITECTURE.md §6.7b.
    public static func pi(transaction: ConfigTransaction) -> AgentIntegrationProfile {
        AgentIntegrationProfile(
            agentID: "pi",
            displayName: "Pi",
            detection: .init(
                agentID: "pi",
                displayName: "Pi",
                executableNames: ["pi"],
                configFiles: [home().appendingPathComponent(".pi/agent/settings.json")]
            ),
            configurator: PiConfigurator(transaction: transaction),
            capabilities: [.detect, .configure, .uninstall, .liveEvents, .testEvent],
            // The same shape as Oh My Pi's: one file the runtime owns in a
            // directory the agent scans, not lines inside a file it owns.
            mechanism: .extensionFile
        )
    }

    /// Antigravity reads its hooks from one named entry in
    /// `~/.gemini/config/hooks.json` (verified against 1.2.3: the CLI logs
    /// how many named hooks it loaded, and every event it fires was captured
    /// on this machine, 2026-09-15).
    public static func antigravity(transaction: ConfigTransaction) -> AgentIntegrationProfile {
        let hooks = home().appendingPathComponent(".gemini/config/hooks.json")
        return AgentIntegrationProfile(
            agentID: "antigravity",
            displayName: "Antigravity",
            detection: .init(
                agentID: "antigravity",
                displayName: "Antigravity",
                executableNames: ["agy"],
                extraSearchPaths: [home().appendingPathComponent(".local/bin")],
                configFiles: [hooks]
            ),
            configurator: AntigravityConfigurator(transaction: transaction),
            capabilities: [.detect, .configure, .uninstall, .liveEvents, .testEvent]
        )
    }

    /// Oh My Pi is one of the two agents here extended by a *file* (Pi is the
    /// other): it loads every `*.ts` in `~/.omp/agent/extensions/` at session
    /// start, so the integration is one file the runtime owns outright rather
    /// than lines inside a file somebody else owns. Installing it is a write, removing it
    /// is a delete, and nothing in omp's own configuration is touched.
    ///
    /// It is also why the note below is absent: this agent *is* configurable.
    /// Its session events arrive from the extension (`--agent omp`), not from
    /// a hook table, so there is no config file for the JSON transaction to
    /// edit and none is needed.
    public static func ohMyPi(transaction: ConfigTransaction) -> AgentIntegrationProfile {
        let agentDirectory = home().appendingPathComponent(".omp/agent")
        return AgentIntegrationProfile(
            agentID: "omp",
            displayName: "Oh My Pi",
            detection: .init(
                agentID: "omp",
                displayName: "Oh My Pi",
                executableNames: ["omp"],
                configFiles: [
                    agentDirectory.appendingPathComponent("config.yml"),
                    agentDirectory.appendingPathComponent("extensions"),
                ]
            ),
            configurator: ExtensionFileConfigurator(
                agentID: "omp",
                directory: agentDirectory.appendingPathComponent("extensions"),
                transaction: transaction
            ),
            capabilities: [.detect, .configure, .uninstall, .liveEvents, .testEvent],
            mechanism: .extensionFile
        )
    }

    public static func all(transaction: ConfigTransaction) -> [AgentIntegrationProfile] {
        [
            claudeCode(transaction: transaction),
            grok(transaction: transaction),
            codex(transaction: transaction),
            pi(transaction: transaction),
            antigravity(transaction: transaction),
            ohMyPi(transaction: transaction),
        ]
    }

    public static func profile(
        for agentID: String,
        transaction: ConfigTransaction
    ) -> AgentIntegrationProfile? {
        all(transaction: transaction).first { $0.agentID == agentID }
    }
}
