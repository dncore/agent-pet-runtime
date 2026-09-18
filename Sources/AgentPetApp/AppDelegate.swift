import AgentPetCore
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: PetWindow!
    private var petView: PetView!
    private let controller = PetController()

    private let bridge = BridgeCoordinator()

    private var statusItem: NSStatusItem?

    /// How big the pet is drawn, in points across. Seeded from the stored
    /// settings before the window exists, then kept in step with the manager's
    /// copy of them — the frame callback is where a change is noticed, because
    /// it is already the one thing that runs every frame.
    private var petWidth: CGFloat = CGFloat(AppConfig.PetConfig.defaultWidth)

    /// Keeps the panel's width from twitching as sessions come and go: the
    /// panel fits itself to its content now, and content changes with every
    /// event. Grows at once, shrinks once the content has stayed small.
    private var widthGovernor = PanelWidthGovernor()

    /// Whether the pet is on screen. Codex calls putting it away "tuck away";
    /// the app stays in the menu bar either way, which is the only way back.
    private var isPetVisible = true
    private var library: [PetLibrary.Entry] = []

    /// Folders that look like pets and were refused, from the launch scan.
    /// Kept beside the library so the no-pets alert can say why it is empty.
    private var skippedPets: [PetLibraryScanner.Skipped] = []
    private var selectedPetID: String?
    /// Last panel written to the verbose log, so the frame loop does not
    /// repeat it sixty times a second.
    private var lastLoggedPanel: MessagePanel?

    /// Last atlas cell written to the verbose log, for the same reason.
    private var lastLoggedFrame: AnimationFrame?

    /// Set when a check finds a newer release, so both menus can say so.
    private var availableUpdate: UpdateCheck.Release?
    private var model: AgentPetModel?
    private var managerWindow: MainWindowController?

    private static let positionKey = "pet.window.origin"

    /// Pets that have already said hello. Codex keeps the same note — its
    /// greeting is once per pet, not once per launch, so a user with three
    /// pets meets each of them as themselves.
    private static let greetedKey = "pet.greeted.ids"

    /// Signal sources that turn a termination signal into a normal quit.
    ///
    /// `brew upgrade` stops the old process before replacing the bundle, and
    /// the cask does it with SIGTERM. Left alone that is an abrupt death: no
    /// `applicationWillTerminate`, so the window position goes unsaved and the
    /// bridge socket is left behind for the next launch to clean up. Turning
    /// the signal into `terminate` makes an upgrade stop the pet exactly the
    /// way the Quit menu item does.
    private var terminationSignals: [DispatchSourceSignal] = []

    private func handleTerminationSignals() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            terminationSignals.append(source)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        handleTerminationSignals()
        buildMainMenu()
        // Read before the window exists: the size decides the window's frame,
        // and the model that owns the settings is built later still.
        let stored = AppConfigStore().load()
        petWidth = CGFloat(stored.pet.width)
        isPetVisible = stored.pet.visible
        buildWindow()
        buildStatusItem()
        let panelConfig = { [weak self] in
            self?.model?.config.messagePanel ?? MessagePanelConfig()
        }
        // The panel speaks in display names; the registry is where they live.
        let agentNames = Dictionary(
            uniqueKeysWithValues: AgentProfiles.all.map { ($0.agentID, $0.displayName) }
        )
        controller.panelConfig = panelConfig
        controller.agentNames = { agentNames }

        var firstFrame = true
        controller.onFrame = { [weak self] image, frame, panel in
            if firstFrame, CommandLine.arguments.contains("--verbose") {
                firstFrame = false
                FileHandle.standardError.write(Data(
                    "[pet] first frame delivered: \(image.map { "\($0.width)x\($0.height)" } ?? "nil")\n".utf8
                ))
            }
            guard let self else { return }
            // The size setting can change while the pet is on screen, and the
            // view needs the width for the message line's own size.
            if let configured = self.model?.config.pet.width {
                self.petWidth = CGFloat(configured)
            }
            self.petView.petWidth = self.petWidth
            self.petView.show(image)
            self.petView.show(panel, config: panelConfig())
            self.resizeWindow(for: panel, config: panelConfig())
            self.logPanelChange(panel)
            self.logFrameChange(frame)
        }

        let scan = PetLibrary.scan()
        library = scan.entries
        skippedPets = scan.skipped

        // `--pet <id>` picks a specific one, which is how the self-test can be
        // pointed at a V2 pet to exercise the gaze rows. It is an override for
        // this run only, so it is deliberately not written back: the user's
        // own choice must survive a diagnostic run.
        var chosen = library.first
        if let index = CommandLine.arguments.firstIndex(of: "--pet"),
           index + 1 < CommandLine.arguments.count {
            let wanted = CommandLine.arguments[index + 1].lowercased()
            chosen = library.first {
                $0.definition.id.lowercased() == wanted
                    || $0.root.lastPathComponent.lowercased() == wanted
            } ?? library.first
            if chosen == nil || chosen?.definition.id.lowercased() != wanted {
                FileHandle.standardError.write(Data(
                    "[pet] no pet matching '\(wanted)'; using the first available\n".utf8
                ))
            }
        } else {
            chosen = lastUsedPet() ?? chosen
        }

        if let chosen {
            select(pet: chosen)
        } else {
            presentNoPets()
        }

        controller.start()
        // Tucking the pet away has to survive a relaunch, and the window was
        // built before this point.
        setPetVisible(isPetVisible, persist: false)
        // The model exists before the bridge does: an event that arrived in
        // between used to reach the engine but not the manager's view of the
        // world, since `model` was still nil when the bridge delivered it.
        buildModel()
        // A diagnostic run takes none of this: binding the socket would steal
        // the running pet's events for as long as the self-test lasts, and
        // replaying the spool would consume—and delete—a user's undelivered
        // events into a process that is about to exit.
        if !HeadlessMode.isActive {
            startBridge()
            replaySpooledEvents()
            // Before anything reads health: a config written by an older
            // version can hold a hook line this one no longer installs, and
            // that line can be gating the agent right now.
            model?.removeObsoleteEntries()
        }
        rebuildMenu()
        checkForUpdatesInBackground()

        if CommandLine.arguments.contains("--selftest") {
            let status = RenderSelfTest.run(controller: controller, view: petView, petWidth: petWidth)
            exit(status)
        }

        // Builds the manager window on launch so a crash in the view hierarchy
        // shows up in a smoke test rather than the first time a user opens it.
        if CommandLine.arguments.contains("--open-manager") {
            openManager()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
        bridge.stop()
        savePosition()
    }

    private func startBridge() {
        bridge.onEvent = { [weak self] event in
            guard let self else { return }
            self.controller.ingest(event)
            // A status-line reading is not the hook pipeline working; counting
            // it as one would make a broken install of hooks look healthy to
            // the agent card.
            if event.kind != .contextUpdate {
                self.model?.noteEvent(agentID: event.agentID)
            }
            self.pushActivities()

            if CommandLine.arguments.contains("--verbose") {
                FileHandle.standardError.write(Data(
                    "[bridge] \(event.agentID) \(event.kind.rawValue) session=\(event.sessionID)\n".utf8
                ))
            }
        }
        bridge.onStatusChange = { [weak self] in
            self?.rebuildMenu()
        }
        if let index = CommandLine.arguments.firstIndex(of: "--log-events"),
           index + 1 < CommandLine.arguments.count {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            bridge.captureURL = url
            FileHandle.standardError.write(Data("""
                [pet] writing an event log to \(url.path)
                [pet] it records which events arrived and what state they mapped to, not \
                what the agent was doing: tool arguments, tool output, and prompts are \
                dropped. Written owner-only (0600). Delete it when done.

                """.utf8))
        }
        bridge.start()
    }

    /// Replays events that arrived while the app was not running.
    ///
    /// A quit-and-relaunch — and above all a `brew upgrade --cask`, which
    /// stops the old app before replacing it — used to leave the pet with
    /// amnesia: a session that was mid-turn seconds before the restart was
    /// invisible until its next hook, which for a long tool is minutes away.
    /// The shim writes those events down; this hands them to the same path a
    /// live event takes, oldest first, before anything else is shown.
    private func replaySpooledEvents() {
        let replayed = EventSpool.drain { [weak self] envelope in
            self?.bridge.deliver(envelope)
        }
        guard replayed > 0, CommandLine.arguments.contains("--verbose") else { return }
        FileHandle.standardError.write(Data(
            "[pet] replayed \(replayed) event(s) that arrived while the app was not running\n".utf8
        ))
    }

    private func buildModel() {
        let model = AgentPetModel(
            root: BridgeSocketLocation.applicationSupportDirectory,
            shimPath: shimPath
        )
        model.onUsePet = { [weak self] pet in
            self?.loadPet(at: pet.root, name: pet.name)
        }
        // The settings toggle and the system setting both have to be on for
        // the pet to hold still; the system one alone is what Codex honours.
        controller.shouldReduceMotion = { [weak model] in
            guard let model, model.config.pet.respectsReduceMotion else { return false }
            return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        model.onTestEvent = { [weak self] event in
            self?.controller.ingest(event)
            self?.pushActivities()
        }
        // One directory, one list: the menu bar's copy of the library follows
        // the manager's, so a pet installed while the manager is open shows up
        // in the Pet menu without a relaunch.
        model.onPetsChanged = { [weak self] pets in
            self?.library = pets
            self?.rebuildMenu()
        }
        model.bridgeSummary = { [weak self] in
            guard let bridge = self?.bridge else {
                return DiagnosticsBundle.BridgeSummary(
                    isListening: false, socketPath: "", eventsReceived: 0, malformedFrames: 0
                )
            }
            return DiagnosticsBundle.BridgeSummary(
                isListening: bridge.isListening,
                socketPath: bridge.status.socketPath,
                eventsReceived: bridge.status.receivedCount,
                malformedFrames: bridge.malformedFrameCount
            )
        }
        // The pet was chosen above, before the model existed. Hand the choice
        // over so the manager marks it as the one on the desktop.
        model.currentPetID = selectedPetID
        self.model = model
        self.managerWindow = MainWindowController(model: model)
        // While the manager is open it has to be true *now*: the engine
        // expires states on a clock and moves focus without any event, so a
        // list that only refreshed on events could sit there contradicting
        // the pet beside it on screen.
        var ticks = 0
        managerWindow?.onTick = { [weak self] in
            self?.pushActivities()
            // Health re-reads each agent's integration record, and the hook
            // entries in the config file, from disk. Those change when an agent
            // is configured — not once a second.
            if ticks.isMultiple(of: 5) { self?.model?.refreshAgentHealth() }
            ticks += 1
        }
        pushActivities()
    }

    /// Hands the manager window the engine's current view of the world.
    private func pushActivities() {
        guard let model else { return }
        let activities = controller.currentActivities
        let focused = controller.focusedActivity
        model.updateActivities(activities, focusedID: focused?.id)
    }

    /// Loads a pet package by path. Shared by the menu and the manager window
    /// so both go through one code path.
    private func loadPet(at root: URL, name: String) {
        do {
            let loaded = try PetPackageLoader().load(from: root)
            try controller.load(loaded)
            controller.loadedPetName = name
            selectedPetID = loaded.definition.id
            model?.currentPetID = loaded.definition.id
            greetIfNew(petID: loaded.definition.id, name: name)
            rebuildMenu()
            if CommandLine.arguments.contains("--verbose") {
                FileHandle.standardError.write(Data(
                    "[pet] selected \(loaded.definition.id) from \(root.path)\n".utf8
                ))
            }
        } catch {
            NSLog("Failed to load pet at \(root.path): \(error)")
        }
    }

    /// Says hello, once per pet.
    ///
    /// A diagnostic run is exempt: `--selftest` and `--diagnose` load a pet
    /// through this same path, and spending the user's greeting on a test
    /// would mean never seeing it in real use.
    private func greetIfNew(petID: String, name: String) {
        guard !HeadlessMode.isActive else { return }
        var greeted = UserDefaults.standard.stringArray(forKey: Self.greetedKey) ?? []
        guard !greeted.contains(petID) else { return }
        greeted.append(petID)
        UserDefaults.standard.set(greeted, forKey: Self.greetedKey)
        controller.introduce(petName: name)
    }

    /// The pet the user last put on the desktop, resolved against what is
    /// installed right now.
    ///
    /// A saved id that no longer resolves — the pet was removed, or its folder
    /// renamed — is simply not a match, and the caller falls back to the first
    /// pet. The stale id is left on disk rather than cleared: reinstalling the
    /// pet, or naming the folder back, restores the choice.
    private func lastUsedPet() -> PetLibrary.Entry? {
        guard let id = AppConfigStore().load().pet.defaultPetID else { return nil }
        return library.first { $0.definition.id == id }
    }

    @objc private func openUpdatePage() {
        guard let update = availableUpdate else { return }
        NSWorkspace.shared.open(update.page)
    }

    /// Tucks the pet away, or wakes it: the same switch Codex puts in its
    /// settings, where ours belongs in the menu bar the app lives in.
    @objc private func togglePetVisibility() {
        setPetVisible(!isPetVisible, persist: true)
        rebuildMenu()
    }

    private func setPetVisible(_ visible: Bool, persist: Bool) {
        isPetVisible = visible
        if visible {
            // A panel should not come back at the width it had before it was
            // put away, and the governor's whole job is remembering widths.
            widthGovernor.reset()
            presentPetWindow()
            // Frames are only worth choosing while somebody can see them.
            controller.start()
        } else {
            window.orderOut(nil)
            controller.stop()
        }
        if persist { model?.rememberPetVisibility(visible) }
        if CommandLine.arguments.contains("--verbose") {
            FileHandle.standardError.write(Data(
                "[pet] pet \(visible ? "awake" : "tucked away")\n".utf8
            ))
        }
    }

    /// The window's View menu toggles the sidebar the same way its toolbar
    /// button does.
    @objc private func toggleManagerSidebar() {
        guard let model else { return }
        model.showsSidebar.toggle()
    }

    @objc private func openManager() {
        model?.refreshAll()
        managerWindow?.show()
    }

    /// ⌘, — the manager, on its Settings section.
    ///
    /// In the main menu, and only there. The status menu deliberately carries
    /// no shortcut: an accessory app with a nonactivating pet panel is never
    /// the active one, so a key equivalent in that menu would do nothing while
    /// advertising itself. The main menu is displayed exactly when the app is
    /// frontmost, which for this app is exactly when the manager window is
    /// open — so the one thing left for ⌘, here is to work while the user is
    /// already in the manager, wherever in it they are.
    ///
    /// Which is also why an open manager is only re-fronted rather than
    /// re-opened: `openManager`'s refresh is a measured 445ms of spawning one
    /// `--version` process per agent, and a section switch needs none of it.
    /// That wait, plus the view tree the window used to rebuild on the way in,
    /// was the whole of the second the shortcut took to show Settings.
    @objc private func openSettings() {
        model?.section = .settings
        guard managerWindow?.isOpen != true else {
            managerWindow?.show()
            return
        }
        openManager()
    }

    // MARK: - Window

    private func buildWindow() {
        let size = PetWindow.size(forWidth: petWidth)
        let origin = restoredOrigin() ?? defaultOrigin(for: size)
        window = PetWindow(contentRect: NSRect(origin: origin, size: size))

        petView = PetView(frame: NSRect(origin: .zero, size: size))
        petView.autoresizingMask = [.width, .height]
        petView.petWidth = petWidth
        petView.onDragBegan = { [weak self] in
            self?.controller.beginDrag()
        }
        petView.onDrag = { [weak self] origin in
            guard let self, let window = self.window else { return }

            let previous = window.frame.origin
            self.controller.updateDrag(dx: origin.x - previous.x, dy: origin.y - previous.y)

            // Keep at least a grabbable corner on some display. A pet dragged
            // fully off-screen has no dock icon and no window list entry, so
            // there would be no way to get it back.
            window.setFrameOrigin(
                WindowDrag.clamped(
                    origin: origin,
                    size: window.frame.size,
                    into: NSScreen.screens.map(\.visibleFrame)
                )
            )
        }
        petView.onDragEnded = { [weak self] in
            self?.controller.endDrag()
            self?.savePosition()
        }
        petView.onHoverBegan = { [weak self] in
            self?.controller.beginHover()
        }
        petView.onHoverEnded = { [weak self] in
            self?.controller.endHover()
        }
        petView.onClick = { [weak self] in
            self?.controller.greet()
        }
        petView.onDoubleClick = { [weak self] in
            self?.openManager()
        }
        petView.onRightClick = { [weak self] event in
            guard let self else { return }
            NSMenu.popUpContextMenu(self.makeMenu(), with: event, for: self.petView)
        }

        // Lets the pet aim its gaze at the pointer, from the sprite's own
        // centre — not the window's. The window grows upward to hold the
        // panel, so its centre sits `panelHeight / 2` above the pet whenever a
        // session is on screen (20pt for one row), and a pointer aimed from
        // there resolves a neighbouring look pose at close range. Screen
        // coordinates, which is what `LookDirection.angle` expects.
        controller.petCenterProvider = { [weak self] in
            guard let self, let window = self.window else { return nil }
            let sprite = petView.spriteRect
            let centre = CGPoint(x: sprite.midX, y: sprite.midY)
            return window.convertPoint(toScreen: petView.convert(centre, to: nil))
        }
        window.contentView = petView
        presentPetWindow()

        // Draw logging is its own flag: it fires sixty times a second and
        // would bury every other diagnostic.
        PetView.isLoggingFrames = CommandLine.arguments.contains("--verbose-draw")
        if CommandLine.arguments.contains("--verbose") {
            let frame = window.frame
            let onScreen = NSScreen.screens.contains { $0.frame.intersects(frame) }
            FileHandle.standardError.write(Data("""
                [pet] window frame=\(frame) visible=\(window.isVisible) \
                onAnyScreen=\(onScreen) screen=\(String(describing: window.screen?.frame)) \
                level=\(window.level.rawValue) alpha=\(window.alphaValue)

                """.utf8))
        }
    }

    /// Puts the pet's window on screen — unless this is a diagnostic run.
    ///
    /// The window still exists either way: `--selftest` draws through the
    /// view's own backing store, which needs a window but not a visible one,
    /// and CI has no screen at all. What the guard buys is that a dozen
    /// self-test runs in a row do not strobe a pet on and off somebody's
    /// desktop while they are working on the code that runs them.
    private func presentPetWindow() {
        guard !HeadlessMode.isActive else { return }
        window.orderFrontRegardless()
    }

    private func defaultOrigin(for size: NSSize) -> NSPoint {
        guard let screen = NSScreen.screens.first else { return NSPoint(x: 100, y: 100) }
        return PetWindow.defaultOrigin(on: screen)
    }

    /// Logs which cell the pet is drawing, once per change.
    ///
    /// The state rides along because the two are not the same question: a
    /// state can be `running` while the pet draws something else (an idle
    /// gaze, a hover, a drag), and "the pet isn't running while the agent
    /// works" is exactly the gap between the two columns. Without this line
    /// nothing on this machine can see what is on screen.
    private func logFrameChange(_ frame: AnimationFrame?) {
        guard frame != lastLoggedFrame else { return }
        lastLoggedFrame = frame
        guard CommandLine.arguments.contains("--verbose") else { return }
        let state = controller.focusedActivity?.state.rawValue ?? "idle"
        let drawn = frame.map { "\($0.trackName) r\($0.row)c\($0.column)" } ?? "nothing"
        FileHandle.standardError.write(Data(
            "[pet] frame: state=\(state) drawing=\(drawn)\n".utf8
        ))
    }

    /// Logs what the panel says, once per change, for the frame loop's sake.
    ///
    /// Built from the same layout the view draws, so the line reports what is
    /// on screen rather than every field that happens to exist — a diagnostic
    /// that shows items the user turned off is worse than none.
    private func logPanelChange(_ panel: MessagePanel) {
        guard panel != lastLoggedPanel else { return }
        lastLoggedPanel = panel
        guard CommandLine.arguments.contains("--verbose") else { return }
        let config = model?.config.messagePanel ?? MessagePanelConfig()
        let text = panel.rows.isEmpty
            ? "cleared"
            : panel.rows.map { row in
                MessagePanelLayout.items(for: row, config: config, petWidth: petWidth).map { item in
                    item.secondary.map { "\(item.primary) — \($0)" } ?? item.primary
                }.joined(separator: " · ")
            }.joined(separator: " | ")
        FileHandle.standardError.write(Data("[pet] panel: \(text)\n".utf8))
    }

    /// Grows the window upward when the panel appears, and sideways to the
    /// width the settings ask for.
    ///
    /// The pet does not move: the window is placed so that the sprite stays
    /// exactly where it is, and the panel takes space *above* it, exactly as
    /// Codex reserves rows above its sprite rather than drawing over the
    /// transcript. The bottom edge is what stays put — growing downward would
    /// move the pet every time a session went to work.
    ///
    /// The width is the plan's own: the content's, when the panel is fitting
    /// itself to it, or the settings' maximum. It goes through the governor,
    /// because content changes with events and a bubble that flinched on every
    /// one of them would be worse than one that is occasionally too wide.
    private func resizeWindow(for panel: MessagePanel, config: MessagePanelConfig) {
        guard let window else { return }
        let plan = MessagePanelLayout.plan(for: panel, config: config, petWidth: petWidth)
        let pet = PetWindow.size(forWidth: petWidth)
        let wanted = plan.rows.isEmpty ? pet.width : plan.width
        let width = widthGovernor.width(wanted: wanted, at: Date())
        let height = pet.height + plan.height

        let frame = window.frame
        guard abs(frame.width - width) > 0.5 || abs(frame.height - height) > 0.5 else { return }
        // Where the sprite is now, and the window origin that leaves it there
        // — whichever edge of it the panel is anchored to.
        let spriteX = frame.minX + config.alignment.spriteOriginX(
            inWindowWidth: frame.width, petWidth: petWidth
        )
        window.setFrame(
            NSRect(
                x: config.alignment.windowOriginX(
                    forSpriteX: spriteX, windowWidth: width, petWidth: petWidth
                ),
                y: frame.minY,
                width: width,
                height: height
            ),
            display: true
        )
    }

    private func restoredOrigin() -> NSPoint? {
        guard let saved = UserDefaults.standard.string(forKey: Self.positionKey) else { return nil }
        let parts = saved.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }

        let point = NSPoint(x: parts[0], y: parts[1])
        // A pet restored onto a monitor that is no longer attached would be
        // invisible and unreachable, and has to be brought back rather than
        // trusted.
        guard WindowDrag.isReachable(
            origin: point,
            size: PetWindow.size(forWidth: petWidth),
            screens: NSScreen.screens.map(\.visibleFrame)
        ) else { return nil }

        return point
    }

    private func savePosition() {
        guard let frame = window?.frame else { return }
        // Stored as the origin the window would have at its resting width, so
        // the saved point is the sprite's own left edge rather than the
        // frame's corner — which depends on how wide the panel happened to be,
        // and on which edge of the pet it is anchored to. Otherwise a wide
        // panel at one quit and a narrow one at the next would walk the pet
        // sideways a little on every relaunch.
        let alignment = model?.config.messagePanel.alignment ?? MessagePanelConfig().alignment
        let anchorX = frame.minX + alignment.spriteOriginX(
            inWindowWidth: frame.width, petWidth: petWidth
        )
        UserDefaults.standard.set("\(anchorX),\(frame.minY)", forKey: Self.positionKey)
    }

    /// Explains that no pet was found.
    ///
    /// Modal only when there is somebody to dismiss it. A `runModal` on a
    /// machine with no user — a CI runner, most obviously — blocks forever, and
    /// the app appears to hang rather than to report a missing pet.
    ///
    /// "Nothing in <that directory>" is the wrong thing to say when the user's
    /// pet folder is sitting in it: anything the scan refused is listed here
    /// with its reason, which for many users is the only place they will ever
    /// see it.
    private func presentNoPets() {
        let directory = PetLibrary.petsDirectory.path
        var explanation = """
            Nothing in \(directory).

            Install one with:
                npx codex-pets add <pet-id>

            …or drop any package folder in there.
            """
        if !skippedPets.isEmpty {
            let lines = skippedPets.map { "    \($0.name) — \($0.reason)" }.joined(separator: "\n")
            explanation = """
                \(skippedPets.count) folder(s) in \(directory) look like pets but cannot be played:

                \(lines)

                Install one with:
                    npx codex-pets add <pet-id>

                …or drop any package folder in there.
                """
        }

        guard !HeadlessMode.isActive else {
            FileHandle.standardError.write(Data("[pet] no pet packages found.\n\n\(explanation)\n\n".utf8))
            return
        }

        let alert = NSAlert()
        alert.messageText = skippedPets.isEmpty
            ? "No pet packages found"
            : "No playable pet packages found"
        alert.informativeText = explanation
        alert.alertStyle = .informational
        alert.runModal()
    }

    // MARK: - About, updates

    /// The standard About panel, with the shape of the app in its credits.
    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Agent Pet Runtime",
            .applicationVersion: UpdateCheck.currentVersion,
            .credits: NSAttributedString(
                string: "A desktop pet that reacts to what your CLI coding agents are doing.\n"
                    + "github.com/dncore/agent-pet-runtime",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ),
        ])
    }

    /// Checks the release feed now and says what it found. The automatic check
    /// at launch stays quiet; this one was asked for, so it answers.
    @objc private func checkForUpdates() {
        Task { @MainActor in
            let outcome = await UpdateCheck.run()
            noteUpdate(outcome)
            present(outcome)
        }
    }

    private func present(_ outcome: UpdateCheck.Outcome) {
        let alert = NSAlert()
        switch outcome {
        case .upToDate(let current):
            alert.messageText = "Agent Pet Runtime \(current) is the latest version."
            alert.informativeText = ""
            alert.addButton(withTitle: "OK")
        case .available(let release, let current):
            alert.messageText = "Agent Pet Runtime \(release.version) is available."
            alert.informativeText = "You are running \(current)."
            alert.addButton(withTitle: "Open Release Page")
            alert.addButton(withTitle: "Later")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(release.page)
            }
            return
        case .failed(let reason):
            alert.messageText = "Could not check for updates."
            alert.informativeText = reason
            alert.addButton(withTitle: "OK")
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Records what a check found, so the menu can carry it.
    private func noteUpdate(_ outcome: UpdateCheck.Outcome) {
        switch outcome {
        case .available(let release, _):
            if availableUpdate != release {
                availableUpdate = release
                rebuildMenu()
            }
            if CommandLine.arguments.contains("--verbose") {
                FileHandle.standardError.write(Data(
                    "[pet] update available: \(release.version)\n".utf8
                ))
            }
        case .upToDate, .failed:
            availableUpdate = nil
        }
    }

    /// A quiet check a few seconds after launch: a newer release only adds a
    /// menu item. Nothing is downloaded, and nothing interrupts the pet.
    private func checkForUpdatesInBackground() {
        guard !HeadlessMode.isActive else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            noteUpdate(await UpdateCheck.run())
        }
    }

    // MARK: - Main menu

    /// The menu bar the app shows while its window is frontmost.
    ///
    /// The app spends most of its life as an accessory with no menu bar at all;
    /// this exists for the manager window, and without it the window is a
    /// classic macOS oddity: no About, no Quit, and copy and paste that do not
    /// work because nothing is bound to them.
    private func buildMainMenu() {
        let name = "Agent Pet Runtime"
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(name)", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        // ⌘, — the shortcut every Mac app gives its settings. It enters the
        // same manager window the status menu's "Open Pet Manager…" does; the
        // difference is the section it lands on.
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(
            title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(
            withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"
        )
        editItem.submenu = editMenu
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let toggleSidebar = NSMenuItem(
            title: "Toggle Sidebar", action: #selector(toggleManagerSidebar), keyEquivalent: "s"
        )
        // ⌃⌘S, the shortcut AppKit gives this command.
        toggleSidebar.keyEquivalentModifierMask = [.control, .command]
        viewMenu.addItem(toggleSidebar)
        viewMenu.addItem(.separator())
        viewMenu.addItem(
            withTitle: "Enter Full Screen",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        viewMenu.items.last?.keyEquivalentModifierMask = [.control, .command]
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"
        )
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"
        )
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main

        if CommandLine.arguments.contains("--verbose") {
            FileHandle.standardError.write(Data(
                "[pet] main menu: \(main.items.count) menus for the manager window\n".utf8
            ))
        }
    }

    // MARK: - Menu

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // The menu bar shows the pet itself: a template image, so AppKit can
        // invert it for dark menu bars and for the highlight when the menu is
        // open. One ink colour and alpha — a colour icon would go unreadable
        // on one theme or the other. The emoji stands in only when the bundle
        // has no icon (running from SwiftPM, say).
        if let image = NSImage(named: "StatusIcon") {
            image.isTemplate = true
            item.button?.image = image
            item.button?.imagePosition = .imageOnly
        } else {
            // The same glyph as an agent with no name of its own, by the same
            // rules: a symbol, not an emoji.
            let fallback = NSImage(systemSymbolName: "pawprint", accessibilityDescription: "Agent Pet Runtime")
            fallback?.isTemplate = true
            item.button?.image = fallback
            item.button?.title = "Agent Pet Runtime"
        }
        statusItem = item
    }

    private func rebuildMenu() {
        statusItem?.menu = makeMenu()
    }

    /// One menu, used by both the status item and the pet's right-click.
    /// Building it per call keeps the two from drifting apart.
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "Agent Pet Runtime", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        // No key equivalent: an accessory app is never the active one, so a
        // menu shortcut here would never fire. Advertising one that does
        // nothing is worse than offering none.
        let openItem = NSMenuItem(title: "Open Pet Manager…",
                                  action: #selector(openManager), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        // Codex's "tuck away" / "wake". The pet is the app's only window, so
        // this is the difference between a pet on screen and a menu bar icon.
        let visibility = NSMenuItem(
            title: isPetVisible ? "Tuck Pet Away" : "Wake Pet",
            action: #selector(togglePetVisibility), keyEquivalent: ""
        )
        visibility.target = self
        menu.addItem(visibility)

        if let update = availableUpdate {
            let item = NSMenuItem(
                title: "Update Available: \(update.version)…",
                action: #selector(openUpdatePage), keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Pets
        let petsItem = NSMenuItem(title: "Pet", action: nil, keyEquivalent: "")
        let petsMenu = NSMenu()
        for entry in library {
            let item = NSMenuItem(title: entry.name, action: #selector(choosePet(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.root.path
            item.state = (entry.definition.id == selectedPetID) ? .on : .off
            petsMenu.addItem(item)
            if !entry.warnings.isEmpty {
                let warning = NSMenuItem(
                    title: "\(entry.warnings.count) compatibility warning(s)",
                    action: nil, keyEquivalent: ""
                )
                warning.image = NSImage(
                    systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Warning"
                )
                warning.isEnabled = false
                petsMenu.addItem(warning)
            }
        }
        if library.isEmpty { petsMenu.addItem(withTitle: "None found", action: nil, keyEquivalent: "") }
        petsItem.submenu = petsMenu
        menu.addItem(petsItem)

        // Animation preview — same resolver the desktop pet uses.
        let previewItem = NSMenuItem(title: "Preview Animation", action: nil, keyEquivalent: "")
        let previewMenu = NSMenu()
        for track in CompatibilityProfile.openAICodexV1.tracks {
            let item = NSMenuItem(title: track.name, action: #selector(previewTrack(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = track.name
            previewMenu.addItem(item)
        }
        previewItem.submenu = previewMenu
        menu.addItem(previewItem)

        // Synthetic agent events — the "Test Integration" path from the spec,
        // exercised through the real activity engine.
        let simulateItem = NSMenuItem(title: "Simulate Agent Event", action: nil, keyEquivalent: "")
        let simulateMenu = NSMenu()
        for kind in AgentEventKind.allCases {
            let item = NSMenuItem(title: kind.rawValue, action: #selector(simulateEvent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            simulateMenu.addItem(item)
        }
        simulateMenu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Activities", action: #selector(clearActivities), keyEquivalent: "")
        clear.target = self
        simulateMenu.addItem(clear)
        simulateItem.submenu = simulateMenu
        menu.addItem(simulateItem)

        // Bridge status — the first thing to look at when the pet is not
        // reacting to a real agent.
        let bridgeItem = NSMenuItem(title: "Event Bridge", action: nil, keyEquivalent: "")
        let bridgeMenu = NSMenu()

        let state = NSMenuItem(
            title: bridge.isListening ? "● Listening" : "○ Not listening",
            action: nil, keyEquivalent: ""
        )
        state.isEnabled = false
        bridgeMenu.addItem(state)

        let socket = NSMenuItem(title: "  \(bridge.status.socketPath)", action: nil, keyEquivalent: "")
        socket.isEnabled = false
        bridgeMenu.addItem(socket)

        let received = NSMenuItem(
            title: "  \(bridge.status.receivedCount) event(s) received",
            action: nil, keyEquivalent: ""
        )
        received.isEnabled = false
        bridgeMenu.addItem(received)

        if let error = bridge.status.error {
            let failure = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            failure.image = NSImage(
                systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Problem"
            )
            failure.isEnabled = false
            bridgeMenu.addItem(failure)
        }

        if !bridge.recent.isEmpty {
            bridgeMenu.addItem(.separator())
            for recent in bridge.recent.prefix(8) {
                let kind = recent.kind?.rawValue ?? "(unmapped)"
                let item = NSMenuItem(
                    title: "  \(recent.agentID) · \(recent.eventName) → \(kind)",
                    action: nil, keyEquivalent: ""
                )
                item.isEnabled = false
                bridgeMenu.addItem(item)
            }
        }

        bridgeMenu.addItem(.separator())
        let copySetup = NSMenuItem(title: "Copy Hook Setup…", action: #selector(copyHookSetup), keyEquivalent: "")
        copySetup.target = self
        bridgeMenu.addItem(copySetup)

        bridgeItem.submenu = bridgeMenu
        menu.addItem(bridgeItem)

        menu.addItem(.separator())

        let activityItem = NSMenuItem(title: activitySummary(), action: nil, keyEquivalent: "")
        activityItem.isEnabled = false
        menu.addItem(activityItem)

        menu.addItem(.separator())
        let about = NSMenuItem(title: "About Agent Pet Runtime", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        return menu
    }

    private func activitySummary() -> String {
        let activities = controller.currentActivities
        guard !activities.isEmpty else { return "No active sessions" }
        return activities
            .map { "\($0.agentID): \($0.state.rawValue)" }
            .joined(separator: ", ")
    }

    // MARK: - Actions

    private func select(pet entry: PetLibrary.Entry) {
        loadPet(at: entry.root, name: entry.name)
    }

    @objc private func choosePet(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String,
              let entry = library.first(where: { $0.root.path == path })
        else { return }
        select(pet: entry)
        model?.rememberPetSelection(petID: entry.definition.id)
        rebuildMenu()
    }

    @objc private func previewTrack(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        controller.playGesture(named: name)
    }

    @objc private func simulateEvent(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let kind = AgentEventKind(rawValue: raw)
        else { return }

        controller.ingest(AgentEvent(
            agentID: "test-agent",
            sessionID: "test-session",
            kind: kind,
            at: Date(),
            confidence: EventConfidence(level: .high, source: "test"),
            summary: "Synthetic \(raw) event"
        ))
        rebuildMenu()
    }

    @objc private func clearActivities() {
        controller.resetActivities()
        rebuildMenu()
    }

    /// The shim ships beside the app executable, so the running binary's own
    /// location is the reliable way to find it.
    private var shimPath: String {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
        let sibling = executable.deletingLastPathComponent()
            .appendingPathComponent("agentpet-hook")
        return FileManager.default.isExecutableFile(atPath: sibling.path)
            ? sibling.path
            : "/path/to/agentpet-hook"
    }

    /// Writes a ready-to-paste Claude Code hook block to the clipboard.
    ///
    /// Deliberately a copy rather than an automatic edit. The runtime holds
    /// itself to backup → modify → validate → rollback before touching
    /// anyone's agent config, and that transaction is not built yet. Handing
    /// the user the exact block is honest about what has been proven.
    @objc private func copyHookSetup() {
        let json = HookSetup.claudeCodeJSON(shimPath: shimPath)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(json, forType: .string)

        let alert = NSAlert()
        alert.messageText = "Claude Code hook configuration copied"
        alert.informativeText = """
            Paste the "hooks" block into ~/.claude/settings.json, then restart \
            Claude Code.

            Shim: \(shimPath)

            Back up that file first — the runtime does not yet have its \
            backup/rollback transaction, so this is a manual edit.
            """
        alert.alertStyle = .informational
        alert.runModal()
    }
}
