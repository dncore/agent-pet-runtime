import AgentPetCore
import AppKit
import Foundation

/// Command-line equivalents of the manager window's actions.
///
/// Every operation the GUI offers is available here too, so the runtime can be
/// driven from a script or a terminal — and so the operations can be verified
/// without a screen.
enum CommandLineTool {

    static let helpText = """
    Agent Pet Runtime — a desktop pet for your CLI agents.

    USAGE
      AgentPet                        Run the pet (menu bar only)
      AgentPet <command> [options]

    AGENTS
      --status                        Show each agent's detection and integration
      --configure <agent-id>          Install the integration for an agent
      --unconfigure <agent-id>        Remove exactly what it wrote

      Agents: claude-code, grok, codex, pi, antigravity, omp

    DIAGNOSTICS
      --diagnose                      Report what is discoverable, and why
      --diagnose --export-frames <dir>  Write every animation frame to <dir>
      --selftest                      Render each state and measure the output
      --log-events <path>             Capture events (off unless asked; see below)

    OTHER
      --pet <id>                      Start with a specific pet
      --open-manager                  Open the manager window at launch
      --verbose                       Log each event as it arrives
      --verbose-draw                  Log every redraw (very noisy)
      --help                          Show this
      --version                       Show the version

    NOTES
      Nothing is uploaded. The runtime reads session ids, working
      directories, and event names — never prompts, model output, or source.

      Model, context, cost, and rate limits are off by default. Turning
      them on in the manager wraps Claude Code's status line: the runtime
      keeps the fields it can show, and runs your own status line command
      unchanged.

      Events that arrive while the app is not running are held in
      pending-events/ and replayed at the next launch, reduced to those same
      fields. Files are written owner-only (0600) and removed as they are read.

      --log-events writes a diagnostic capture and is off by default. It
      records only the fields diagnosis needs, dropping tool arguments, tool
      output, and transcript paths. Files are written owner-only (0600).

      Configuring an agent is transactional: snapshot, back up, edit, verify,
      and restore on any failure. Running it twice changes nothing.
    """

    /// Flags that print something and exit.
    static let informationalFlags = ["--help", "-h", "--version"]

    static func run(arguments: [String]) -> Int32 {
        if arguments.contains("--help") || arguments.contains("-h") {
            print(helpText)
            return 0
        }
        if arguments.contains("--version") {
            print(version())
            return 0
        }

        let root = BridgeSocketLocation.applicationSupportDirectory
        let transaction = ConfigTransaction(
            backupDirectory: root.appendingPathComponent("backups")
        )
        let store = IntegrationStore(directory: root.appendingPathComponent("integrations"))

        if arguments.contains("--status") {
            return printStatus(store: store, transaction: transaction)
        }

        if let index = arguments.firstIndex(of: "--configure"),
           index + 1 < arguments.count {
            return configure(agentID: arguments[index + 1], store: store, transaction: transaction)
        }

        if let index = arguments.firstIndex(of: "--unconfigure"),
           index + 1 < arguments.count {
            return unconfigure(agentID: arguments[index + 1], store: store, transaction: transaction)
        }

        return 0
    }

    // MARK: - Status

    private static func printStatus(store: IntegrationStore, transaction: ConfigTransaction) -> Int32 {
        let profiles = AgentIntegrationRegistry.all(transaction: transaction)
        let detector = AgentDetector(specifications: profiles.map(\.detection))
        let evaluator = IntegrationHealthEvaluator()

        print("Agent integrations")
        print("")
        for profile in profiles {
            let detection = detector.detect(profile.detection)
            let record = store.record(for: profile.agentID)
            let present = profile.configurator.map { $0.entriesPresent(in: record) } ?? false
            // The persisted timestamp is the same evidence the app's card is
            // built from, so this command agrees with it instead of hedging.
            let health = evaluator.health(
                record: record, isDetected: detection.isDetected,
                lastEventAt: record.lastEventAt, entriesPresent: present
            )

            let marker = detection.isDetected ? "●" : "○"
            print("  \(marker) \(profile.displayName)  [\(profile.agentID)]")
            print("      health:      \(health.displayName)")
            print("      executable:  \(detection.executablePath ?? "not found")")
            if let version = detection.version {
                print("      version:     \(version)")
            }
            let installed = profile.mechanism == .extensionFile ? "extension:" : "hooks:"
            print("      " + installed.padding(toLength: 13, withPad: " ", startingAt: 0)
                  + "\(record.entries.count)")
            print("      last event:  \(record.lastEventAt.map(Self.timestamp) ?? "never")")
            print("      configurable:\(profile.configurator == nil ? " no" : " yes")")
        }
        return 0
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    // MARK: - Configure

    private static func configure(
        agentID: String,
        store: IntegrationStore,
        transaction: ConfigTransaction
    ) -> Int32 {
        guard let profile = AgentIntegrationRegistry.profile(for: agentID, transaction: transaction) else {
            print("Unknown agent '\(agentID)'. Known: "
                  + AgentIntegrationRegistry.all(transaction: transaction)
                    .map(\.agentID).joined(separator: ", "))
            return 1
        }
        guard let configurator = profile.configurator else {
            print("\(profile.displayName) has no configurator.")
            // The same sentence the agent's card shows, from the same place.
            if let note = profile.configurationNote { print(note) }
            return 1
        }

        let shim = shimPath()
        let previous = store.record(for: agentID)

        do {
            let outcome = try configurator.configure(
                shimPath: shim, replacing: previous, now: Date()
            )
            try store.save(outcome.record)

            print("\(profile.displayName): \(outcome.didChange ? "configured" : "already configured")")
            // One slot, as wide as the longest label here ("extension:"), so
            // every value in this block starts in the same column — the same
            // rule --status follows.
            func field(_ label: String, _ value: String) -> String {
                "  " + label.padding(toLength: 10, withPad: " ", startingAt: 0) + "  " + value
            }
            let installed = profile.mechanism == .extensionFile ? "extension:" : "hooks:"

            print(field("shim:", shim))
            print(field(installed, "\(outcome.record.entries.count)"))
            for file in outcome.changedFiles { print(field("wrote:", file)) }
            for backup in outcome.backupURLs { print(field("backup:", backup)) }
            if !outcome.didChange {
                print("  (nothing to change — running this again is always safe)")
            }
            if let hint = profile.postConfigureHint {
                print("")
                print(hint)
            }
            return 0
        } catch {
            print("Could not configure \(profile.displayName): \(error)")
            if case ConfigTransactionError.existingContentNotJSON(let path, _) = error {
                print("")
                print("\(path) is not valid JSON. The runtime will not overwrite a file it")
                print("cannot parse, because doing so would discard whatever is in it.")
            }
            if case ConfigurationError.foreignFile(let path) = error {
                print("")
                print("\(path) exists but was not written by the runtime, so it is left")
                print("alone. Move it aside if you want the pet to use that name.")
            }
            return 1
        }
    }

    private static func unconfigure(
        agentID: String,
        store: IntegrationStore,
        transaction: ConfigTransaction
    ) -> Int32 {
        guard let profile = AgentIntegrationRegistry.profile(for: agentID, transaction: transaction),
              let configurator = profile.configurator
        else {
            print("Unknown or unconfigurable agent '\(agentID)'.")
            return 1
        }

        let record = store.record(for: agentID)
        do {
            let outcome = try configurator.uninstall(record, now: Date())
            try store.save(outcome.record)

            print("\(profile.displayName): \(outcome.didChange ? "integration removed" : "nothing to remove")")
            for file in outcome.changedFiles { print("  wrote:  \(file)") }
            let wrote = profile.mechanism == .extensionFile
                ? "the extension file the runtime wrote"
                : "the \(record.entries.count) hook(s) the runtime wrote"
            let verb = profile.mechanism == .extensionFile ? "was" : "were"
            print("  Only \(wrote) \(outcome.didChange ? verb : "would have been") removed.")
            for backup in outcome.backupURLs { print("  backup: \(backup)") }
            if profile.mechanism == .extensionFile {
                // The whole file goes, including anything the user had added to
                // it — saying "anything you wrote is untouched" here would be
                // the opposite of what just happened. With nothing to remove
                // there is no copy either, which is why both sentences live
                // under the same condition as the `backup:` line above.
                if outcome.didChange {
                    print("  The whole file was removed, including anything you had added to it.")
                    print("  A copy was kept in the backup directory before it went.")
                } else {
                    // Four ways to land here, and all of them are real: the file
                    // is gone, it is not valid UTF-8, its marker line was
                    // rewritten, or this agent has no record to match against
                    // (the CLI does not gate on one — only the manager's card
                    // checks `isConfigured` first). Name them all rather than
                    // three of four, which would invite "then which is it?".
                    print("  Nothing was removed. The extension file is missing, is not")
                    print("  readable as UTF-8, no longer carries the recorded marker, or")
                    print("  this agent has no recorded marker to look for.")
                }
            } else {
                print("  Anything you wrote yourself is untouched.")
            }
            return 0
        } catch {
            print("Could not remove the \(profile.displayName) integration: \(error)")
            return 1
        }
    }

    // MARK: - Helpers

    /// The bundle's version, falling back when run straight from SwiftPM.
    static func version() -> String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?): return "Agent Pet Runtime \(short) (\(build))"
        case let (short?, nil):    return "Agent Pet Runtime \(short)"
        default:                   return "Agent Pet Runtime 0.1.0-dev"
        }
    }

    static func shimPath() -> String {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let sibling = executable.deletingLastPathComponent().appendingPathComponent("agentpet-hook")
        return FileManager.default.isExecutableFile(atPath: sibling.path)
            ? sibling.path
            : "/path/to/agentpet-hook"
    }
}
