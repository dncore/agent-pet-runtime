import AgentPetCore
import AppKit
import Foundation

/// Everything the manager windows display and everything they can do.
///
/// All mutation goes through here so the UI never touches the store, the
/// configurator, or the engine directly — which keeps "what can this window
/// change?" answerable by reading one file.
@MainActor
final class AgentPetModel: ObservableObject {

    @Published private(set) var pets: [PetLibrary.Entry] = []
    @Published private(set) var agentStatuses: [AgentStatus] = []
    @Published private(set) var activities: [AgentActivity] = []
    @Published private(set) var focusedActivityID: String?

    /// How long a confirmation stays on screen.
    ///
    /// It is an acknowledgement, not information: the bar spans the bottom of
    /// the window, and one that never leaves is a fixture the user has to
    /// dismiss by hand. Errors are the opposite and stay until dismissed.
    static let statusDuration: TimeInterval = 5

    private var statusDismissal: Timer?

    @Published var statusMessage: String? {
        didSet {
            statusDismissal?.invalidate()
            statusDismissal = nil
            // A newer message always resets the clock, and `nil` — the close
            // button, or the error path — leaves nothing armed behind it.
            guard let message = statusMessage else {
                Self.log("cleared")
                return
            }
            let timer = Timer(timeInterval: Self.statusDuration, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.statusMessage = nil }
            }
            // `.common`, or resizing and dragging the window would hold the
            // timer until the mouse comes up — the same reason the manager's
            // ticker uses that mode.
            RunLoop.main.add(timer, forMode: .common)
            statusDismissal = timer
            Self.log("\(message) — in \(Int(Self.statusDuration))s")
        }
    }

    /// The bar is short-lived by design, so `--verbose` records when it appears
    /// and when it goes: reading the timing back beats watching the window for
    /// five seconds.
    private static func log(_ line: String) {
        guard CommandLine.arguments.contains("--verbose") else { return }
        FileHandle.standardError.write(Data("[pet] status: \(line)\n".utf8))
    }

    @Published var errorMessage: String?
    @Published var isBusy = false
    /// Which pet the desktop is currently showing, so the list can mark it.
    @Published var currentPetID: String?

    /// Which section the manager window is showing.
    ///
    /// In the model rather than the view because the window rebuilds its view
    /// tree every time it is opened again (see `MainWindowController.show`),
    /// and a `@State` selection would come back as Activity every time.
    @Published var section: ManagerSection = .activity

    /// Whether the manager's sidebar is showing. Also in the model, for the
    /// same reason: a rebuild must not reopen the manager with the sidebar
    /// back, having just been hidden.
    @Published var showsSidebar = true

    /// Persisted user settings.
    @Published var config: AppConfig {
        didSet { if config != oldValue { saveConfig() } }
    }

    let integrationService: AgentIntegrationService
    let transaction: ConfigTransaction
    let root: URL

    /// Resolved at launch and passed in; the UI never guesses it.
    let shimPath: String

    private let onActivitiesChanged: ([AgentActivity], String?) -> Void
    private let configStore: AppConfigStore
    let transitionLog: TransitionLog

    init(
        root: URL,
        shimPath: String,
        onActivitiesChanged: @escaping ([AgentActivity], String?) -> Void = { _, _ in }
    ) {
        self.root = root
        self.shimPath = shimPath
        self.transaction = ConfigTransaction(
            backupDirectory: root.appendingPathComponent("backups")
        )
        self.integrationService = AgentIntegrationService(
            store: IntegrationStore(directory: root.appendingPathComponent("integrations")),
            detector: AgentDetector(specifications: []),
            evaluator: IntegrationHealthEvaluator()
        )
        self.configStore = AppConfigStore(
            url: root.appendingPathComponent("config.json")
        )
        self.config = configStore.load()
        self.transitionLog = TransitionLog(
            limit: max(1, configStore.load().diagnostics.transitionHistoryLimit)
        )
        self.onActivitiesChanged = onActivitiesChanged
    }

    func saveConfig() {
        try? configStore.save(config)
    }

    // MARK: - Refresh

    func refreshAll() {
        refreshPets()
        refreshAgents()
    }

    func refreshPets() {
        pets = PetLibrary.discover()
        onPetsChanged?(pets)
    }

    /// Called whenever the pet list is re-read, so the menu bar's copy of it
    /// cannot drift from the manager's. They are the same directory; they
    /// should never be two different answers.
    var onPetsChanged: (([PetLibrary.Entry]) -> Void)?

    /// Full refresh, including detection — which spawns a `--version` process
    /// per agent, so it runs when the manager opens rather than on a timer.
    func refreshAgents() {
        let profiles = AgentIntegrationRegistry.all(transaction: transaction)
        let detector = AgentDetector(specifications: profiles.map(\.detection))
        agentStatuses = profiles.map { integrationService.status(
            for: $0, detection: detector.detect($0.detection)
        ) }
    }

    /// Re-derives health from the facts that change between full refreshes —
    /// whether events have arrived, and whether our hooks are still in the
    /// config file. Detection results are reused.
    ///
    /// Without this the card is a photograph: it was computed when the window
    /// opened, so it kept saying "no events have arrived recently" while event
    /// after event filled the Activity tab beside it.
    func refreshAgentHealth() {
        guard !agentStatuses.isEmpty else { return }
        agentStatuses = agentStatuses.map {
            integrationService.status(for: $0.profile, detection: $0.detection)
        }
    }

    func updateActivities(_ activities: [AgentActivity], focusedID: String?) {
        self.activities = activities
        self.focusedActivityID = focusedID
        if config.diagnostics.loggingEnabled {
            for activity in activities { transitionLog.record(activity) }
        }
    }

    // MARK: - Diagnostics

    func exportDiagnostics(to url: URL) {
        run("Exported diagnostics") {
            let bundle = DiagnosticsBundle(
                app: DiagnosticsBundle.currentAppInfo(),
                bridge: bridgeSummary(),
                pets: pets.map {
                    DiagnosticsBundle.PetSummary(
                        id: $0.id,
                        displayName: $0.name,
                        profile: $0.definition.profile.rawValue,
                        compatibilityWarningCount: $0.warnings.count
                    )
                },
                agents: agentStatuses.map {
                    DiagnosticsBundle.AgentSummary(
                        agentID: $0.profile.agentID,
                        detected: $0.detection.isDetected,
                        executablePath: $0.detection.executablePath,
                        version: $0.detection.version,
                        integrationStatus: $0.record.status.rawValue,
                        health: $0.health.displayName,
                        hookCount: $0.record.entries.count,
                        lastEventAt: $0.lastEventAt
                    )
                },
                transitions: transitionLog.transitions
            )
            try bundle.json().write(to: url, options: .atomic)
            statusMessage = "Diagnostics written to \(url.lastPathComponent)"
        }
    }

    /// Filled in by the app once the bridge is running.
    var bridgeSummary: () -> DiagnosticsBundle.BridgeSummary = {
        DiagnosticsBundle.BridgeSummary(
            isListening: false, socketPath: "", eventsReceived: 0, malformedFrames: 0
        )
    }

    func noteEvent(agentID: String) {
        integrationService.recordEvent(agentID: agentID)
    }

    // MARK: - Pet actions

    /// There is no install, upgrade, or uninstall here on purpose. Pets belong
    /// to Codex: `npx codex-pets add <id>` installs and updates them, and
    /// deleting a folder removes one. A second manager inside this app would
    /// be a second source of truth.
    func usePet(_ pet: PetLibrary.Entry) {
        onUsePet?(pet)
        currentPetID = pet.id
        rememberPetSelection(petID: pet.id)
        statusMessage = "“\(pet.name)” is now on the desktop."
    }

    /// Records which pet the desktop is showing, so the next launch restores it.
    ///
    /// Takes an id rather than an entry because the menu bar picks pets
    /// straight out of the library as well, and both must land on the same key.
    func rememberPetSelection(petID: String) {
        config.pet.defaultPetID = petID
    }

    /// Records whether the pet is on screen, so tucking it away survives a
    /// relaunch.
    func rememberPetVisibility(_ visible: Bool) {
        config.pet.visible = visible
    }

    /// Set by the app to switch the desktop pet.
    var onUsePet: ((PetLibrary.Entry) -> Void)?

    // MARK: - Context usage (the status-line tap)

    /// Where a session's context usage comes from.
    ///
    /// Hooks do not carry token counts; Claude Code hands them to the status
    /// line instead. The tap runs this app's shim as the status line and
    /// passes the user's own command through it untouched — which is why it
    /// is a switch the user throws, not something installed on first sight.
    func statusLineTap() -> StatusLineTap {
        StatusLineTap(
            configURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/settings.json"),
            store: IntegrationStore(directory: root.appendingPathComponent("integrations")),
            transaction: transaction
        )
    }

    @Published private(set) var contextTap: StatusLineTap.State = .notInstalled

    func refreshContextTap() {
        contextTap = statusLineTap().state()
    }

    func enableContextTap() {
        run("Context usage is on") {
            let outcome = try statusLineTap().configure(shimPath: shimPath)
            statusMessage = outcome.didChange
                ? "Your status line now runs through the runtime. It keeps working exactly as before."
                : "Already installed — nothing to change."
            refreshContextTap()
        }
    }

    func disableContextTap() {
        run("Context usage is off") {
            let outcome = try statusLineTap().uninstall()
            statusMessage = outcome.didChange
                ? "Your original status line is back."
                : "Nothing to remove."
            refreshContextTap()
        }
    }

    // MARK: - Grok context usage (its own status-line tap)

    /// Grok reports the same numbers to its status line, so it gets the same
    /// switch — a separate record and toggle, because the two are installed
    /// and removed independently.
    func grokStatusLine() -> GrokStatusLine {
        GrokStatusLine(
            configURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".grok/config.toml"),
            store: IntegrationStore(directory: root.appendingPathComponent("integrations")),
            transaction: transaction
        )
    }

    @Published private(set) var grokContextTap: GrokStatusLine.State = .notInstalled

    func refreshGrokContextTap() {
        grokContextTap = grokStatusLine().state()
    }

    func enableGrokContextTap() {
        run("Grok context usage is on") {
            let outcome = try grokStatusLine().configure(shimPath: shimPath)
            statusMessage = outcome.didChange
                ? "Grok's status line now feeds the runtime. It prints nothing."
                : "Already installed — nothing to change."
            refreshGrokContextTap()
        }
    }

    func disableGrokContextTap() {
        run("Grok context usage is off") {
            let outcome = try grokStatusLine().uninstall()
            statusMessage = outcome.didChange
                ? "Grok's status line is back to disabled."
                : "Nothing to remove."
            refreshGrokContextTap()
        }
    }

    // MARK: - Antigravity context usage (its own status-line tap)

    /// Antigravity's status row is visible by default, so this tap renders a
    /// plain replacement row instead of taking the row away — the one tap
    /// that prints something.
    func antigravityStatusLine() -> AntigravityStatusLine {
        AntigravityStatusLine(
            configURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".gemini/antigravity-cli/settings.json"),
            store: IntegrationStore(directory: root.appendingPathComponent("integrations")),
            transaction: transaction
        )
    }

    @Published private(set) var antigravityContextTap: AntigravityStatusLine.State = .notInstalled

    func refreshAntigravityContextTap() {
        antigravityContextTap = antigravityStatusLine().state()
    }

    func enableAntigravityContextTap() {
        run("Antigravity context usage is on") {
            let outcome = try antigravityStatusLine().configure(shimPath: shimPath)
            statusMessage = outcome.didChange
                ? "Antigravity's status line now feeds the runtime and renders a simple one."
                : "Already installed — nothing to change."
            refreshAntigravityContextTap()
        }
    }

    func disableAntigravityContextTap() {
        run("Antigravity context usage is off") {
            let outcome = try antigravityStatusLine().uninstall()
            statusMessage = outcome.didChange
                ? "Antigravity's original status line is back."
                : "Nothing to remove."
            refreshAntigravityContextTap()
        }
    }

    // MARK: - Agent actions

    func configureAgent(_ status: AgentStatus) {
        run("Configured \(status.displayName)") {
            let outcome = try integrationService.configure(
                agentID: status.profile.agentID,
                shimPath: shimPath,
                transaction: transaction
            )
            let what = status.profile.mechanism == .extensionFile ? "extension" : "hooks"
            var message = outcome.didChange
                ? "Wrote the \(what) to \(outcome.changedFiles.joined(separator: ", "))"
                : "Already configured — nothing to change."
            // Codex's file alone is not enough: its hooks stay skipped until
            // the user trusts them in Codex itself.
            if let hint = status.profile.postConfigureHint {
                message += " " + hint
            }
            statusMessage = message
            refreshAgents()
        }
    }

    func removeAgentIntegration(_ status: AgentStatus) {
        run("Removed \(status.displayName) integration") {
            let outcome = try integrationService.uninstall(
                agentID: status.profile.agentID,
                transaction: transaction
            )
            let what = status.profile.mechanism == .extensionFile ? "extension" : "hooks"
            // A file that did not exist had nothing to copy: the transaction
            // says so by reporting no backup, and the message follows it.
            let kept = outcome.backupURLs.isEmpty ? "" : " A backup of the previous file was kept."
            statusMessage = outcome.didChange ? "Removed the \(what).\(kept)" : "Nothing to remove."
            refreshAgents()
        }
    }

    /// The session id every test event uses, so the UI can tell a test apart
    /// from a real session and offer to stop exactly that one.
    static let testSessionID = "test-session"

    /// How long a test is allowed to sit in the activity list before it
    /// removes itself. It is a demonstration, not work: leaving it running
    /// forever made the activity list a place where nothing could be trusted
    /// to mean anything.
    static let testDuration: TimeInterval = 60

    /// The agent whose test is currently running, if any.
    @Published private(set) var activeTestAgentID: String?
    private var testTimeout: Timer?

    /// Feeds a synthetic event through the real pipeline, which is what makes
    /// it a test of the integration rather than of the animation.
    ///
    /// The test session is short-lived by construction: it is stopped by the
    /// button that started it, or by `testDuration` passing, whichever comes
    /// first.
    func sendTestEvent(agentID: String) {
        stopTest(announce: false)
        activeTestAgentID = agentID

        let event = AgentEvent(
            agentID: agentID,
            sessionID: Self.testSessionID,
            kind: .waitingInput,
            at: Date(),
            confidence: EventConfidence(level: .high, source: "test"),
            summary: "Test event from Agent Pet Runtime"
        )
        onTestEvent?(event)
        statusMessage = "Sent a test event as \(agentID). It stops on its own in "
            + "\(Int(Self.testDuration))s."

        testTimeout = Timer.scheduledTimer(withTimeInterval: Self.testDuration, repeats: false) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.stopTest() }
        }
    }

    /// Ends the test session now: the activity is closed through the same
    /// path a real session closes by, so nothing is left behind.
    func stopTest(announce: Bool = true) {
        testTimeout?.invalidate()
        testTimeout = nil
        guard let agentID = activeTestAgentID else { return }
        activeTestAgentID = nil

        onTestEvent?(AgentEvent(
            agentID: agentID,
            sessionID: Self.testSessionID,
            kind: .sessionClosed,
            at: Date(),
            confidence: EventConfidence(level: .high, source: "test"),
            summary: "Test ended"
        ))
        if announce { statusMessage = "Test stopped." }
    }

    /// Whether this activity is the running test.
    func isTestActivity(_ activity: AgentActivity) -> Bool {
        activity.sessionID == Self.testSessionID && activity.agentID == activeTestAgentID
    }

    var onTestEvent: ((AgentEvent) -> Void)?

    // MARK: - Activity actions

    func focus(_ activity: AgentActivity) {
        // v0.1 cannot raise another app's window: hook payloads carry no
        // terminal identity. Opening the project directory is the honest
        // fallback, and the design allows for it.
        guard let target = activity.focusTarget, let path = target.path else {
            statusMessage = "No project directory is known for this session."
            return
        }
        switch target.kind {
        case .directory, .file:
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            statusMessage = "Opened \(path)"
        case .none:
            statusMessage = "This session has no location to open."
        }
    }

    // MARK: - Plumbing

    private func run(_ successMessage: String, _ work: () throws -> Void) {
        isBusy = true
        defer { isBusy = false }
        do {
            try work()
            statusMessage = successMessage
            errorMessage = nil
        } catch {
            errorMessage = describe(error)
            statusMessage = nil
        }
    }

    /// Turns errors into something a user can act on rather than a type name.
    private func describe(_ error: Error) -> String {
        switch error {
        case let ConfigTransactionError.concurrentModification(path):
            return "\(path) changed while it was being edited. Nothing was written — try again."
        case let ConfigTransactionError.existingContentNotJSON(path, _):
            return "\(path) is not valid JSON. Fix it first; the runtime will not overwrite it."
        case let ConfigTransactionError.unreadable(path, detail):
            return "Could not read \(path): \(detail)"
        case let ConfigurationError.unknownAgent(id):
            return "No configurator exists for \(id)."
        case let ConfigurationError.foreignFile(path):
            return "\(path) exists but was not written by the runtime. It is left alone."
        case let PetPackageError.manifestInvalid(name, detail):
            return "“\(name)” has an unusable pet.json: \(detail)"
        case let PetPackageError.manifestNotFound(name):
            return "“\(name)” has no pet.json."
        default:
            return "\(error)"
        }
    }
}
