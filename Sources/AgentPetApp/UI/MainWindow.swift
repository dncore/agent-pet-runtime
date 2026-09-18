import AgentPetCore
import AppKit
import SwiftUI

/// The four top-level sections, matching the information architecture in the
/// design.
enum ManagerSection: String, CaseIterable, Identifiable {
    case activity = "Activity"
    case pets = "Pets"
    case agents = "Agents"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .activity: return "waveform.path.ecg"
        case .pets:     return "pawprint"
        case .agents:   return "cpu"
        case .settings: return "gearshape"
        }
    }
}

struct MainWindowView: View {
    @ObservedObject var model: AgentPetModel

    /// The sidebar's state, in the model because the window rebuilds its view
    /// tree every time it is opened (see `MainWindowController.show`) and a
    /// `@State` here would start over as "shown" every time.
    private var visibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { model.showsSidebar ? .all : .detailOnly },
            set: { model.showsSidebar = ($0 != .detailOnly) }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: visibility) {
            List(ManagerSection.allCases, selection: $model.section) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        } detail: {
            VStack(spacing: 0) {
                content
                if let error = model.errorMessage {
                    banner(error, color: .red, symbol: "exclamationmark.triangle.fill")
                } else if let status = model.statusMessage {
                    banner(status, color: .secondary, symbol: "info.circle")
                }
            }
            // The window is the app, so its title is the app's name; the
            // section is a subtitle rather than something that renames the
            // window every time a sidebar row is clicked.
            .navigationSubtitle(model.section.rawValue)
        }
        // The sidebar toggle belongs in the toolbar, at the leading edge, where
        // every Mac app puts it — Mail, Notes, Finder. Without a toolbar of its
        // own this window had none: SwiftUI fell back to drawing a toggle
        // inside the sidebar pane, and that fallback is what moved about when
        // the sidebar opened and closed.
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    model.showsSidebar.toggle()
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .help(model.showsSidebar ? "Hide Sidebar" : "Show Sidebar")
                // ⌃⌘S, the shortcut the system gives this command.
                .keyboardShortcut("s", modifiers: [.control, .command])
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        // No refresh here. The view used to re-read pets and re-detect agents
        // on appearing, and the code that opens the window does exactly that
        // first — so every open paid for agent detection twice, a measured
        // 445ms each time (one `--version` process per agent). One refresh per
        // open, in the one place that opens the window.
    }

    @ViewBuilder
    private var content: some View {
        switch model.section {
        case .activity: ActivityView(model: model)
        case .pets:     PetsView(model: model)
        case .agents:   AgentsView(model: model)
        case .settings: SettingsView(model: model)
        }
    }

    private func banner(_ text: String, color: Color, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(text).lineLimit(3)
            Spacer()
            Button {
                model.errorMessage = nil
                model.statusMessage = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
        }
        .font(.callout)
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.3))
    }
}

/// Hosts the manager window.
///
/// A separate window rather than a popover: the pet stays on screen while the
/// user is in here, so changes are visible as they are made.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let model: AgentPetModel

    /// Called once a second while the window is on screen, so the manager
    /// shows the engine's current view rather than the one it had when the
    /// last event arrived.
    var onTick: (() -> Void)?

    private var ticker: Timer?

    /// Where the window opens the first time, and how small it may be made.
    ///
    /// 900x680 rather than something tighter because the Pets page is the tall
    /// one: a 240pt preview, a picker, the pet's description and its grid come
    /// to more than 580pt, so "Use on Desktop" and "Reveal in Finder" sat
    /// below the fold in a window that looked complete (user report,
    /// 2026-09-18). The minimum keeps the preview and its controls on screen;
    /// below that the page is a scroll through one thing at a time.
    private static let defaultContentSize = NSSize(width: 900, height: 680)
    private static let minimumContentSize = NSSize(width: 760, height: 520)

    /// The size the user last left the window at, so making it your own is a
    /// one-time thing. Stored in points in the defaults, like the pet's own
    /// position, and clamped to the minimum in case a later version raises it.
    private static let sizeKey = "manager.window.size"

    private static var openingContentSize: NSSize {
        guard let stored = UserDefaults.standard.string(forKey: sizeKey) else {
            return defaultContentSize
        }
        let parts = stored.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return defaultContentSize }
        return NSSize(width: max(parts[0], minimumContentSize.width),
                      height: max(parts[1], minimumContentSize.height))
    }

    private static func rememberContentSize(_ size: NSSize) {
        UserDefaults.standard.set("\(size.width),\(size.height)", forKey: sizeKey)
    }

    init(model: AgentPetModel) {
        self.model = model
    }

    /// Whether the manager is open — the window exists, and is either on
    /// screen or deliberately never put there.
    ///
    /// The difference between the two things `show()` can be asked to do:
    /// bring back a window that was closed (which needs a new view tree), and
    /// bring a window that is already up to the front (which must not rebuild
    /// it — see below).
    ///
    /// `HeadlessMode` is why this is not simply `isVisible`: a diagnostic run
    /// builds the manager without putting it in front, and a window that was
    /// never presented is not "closed" in the sense the rebuild is for —
    /// there is nothing on screen to keep alive, and `--selftest` opens the
    /// manager precisely to inspect it. Reading it as closed would rebuild the
    /// tree between the two presses the shortcut's own check makes, and have
    /// that check measure a rebuild no user can cause.
    var isOpen: Bool {
        guard let window else { return false }
        return window.isVisible || HeadlessMode.isActive
    }

    /// The app is an accessory — menu bar only, no Dock icon — which is right
    /// for a pet and wrong for a window: an accessory app shows no application
    /// menu at all, so the manager had no About, no Quit and no working copy
    /// and paste. Going regular while the window is open gives it all of that,
    /// and closing the window hands the menu bar back to whatever the user was
    /// actually working in.
    func show() {
        // A diagnostic run builds the window but never puts it in front, and
        // never takes the Dock icon or the focus: `--selftest` opens the
        // manager to check its toolbar, and doing that visibly would take the
        // user out of whatever they were typing in.
        let presents = !HeadlessMode.isActive
        if presents { NSApp.setActivationPolicy(.regular) }
        if CommandLine.arguments.contains("--verbose") {
            FileHandle.standardError.write(Data(
                "[pet] manager open: activation policy regular, menu bar visible\n".utf8
            ))
        }
        startTicking()

        if let window {
            // A fresh view tree, but only for a window that has been off
            // screen.
            //
            // SwiftUI stops delivering updates to a window that has been
            // closed, and reopening it does not bring them back — measured in
            // both directions with a probe, and the reason the preview timers
            // had to learn to stop themselves. Rebuilding costs one decode of
            // the pet thumbnails and buys a window that is alive again; the
            // chosen section lives in the model so it survives the rebuild.
            //
            // A window that is *still* on screen needs none of that: updates
            // reach it live — the section the caller just set lands in it —
            // and rebuilding is what made ⌘, sit there for a measured 200ms
            // before anything moved.
            if !isOpen {
                window.contentViewController = Self.makeContent(model: model)
            }
            if presents {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }

        let window = NSWindow(contentViewController: Self.makeContent(model: model))
        window.title = "Agent Pet Runtime"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // The style a window with a sidebar uses: title and toolbar on one
        // line, the traffic lights inline with them.
        window.toolbarStyle = .unified
        window.contentMinSize = Self.minimumContentSize
        window.setContentSize(Self.openingContentSize)
        window.center()
        window.isReleasedWhenClosed = false
        // Bring the manager forward on whatever the user is actually looking
        // at, rather than on the pet's screen.
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self
        if presents {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        self.window = window
    }

    private static func makeContent(model: AgentPetModel) -> NSViewController {
        NSHostingController(rootView: MainWindowView(model: model))
    }

    /// Remembered as the user drags rather than only at close: the manager is
    /// often open when the app is quit, and `windowWillClose` never runs then.
    func windowDidResize(_ notification: Notification) {
        guard let window else { return }
        Self.rememberContentSize(window.contentRect(forFrameRect: window.frame).size)
    }

    func windowWillClose(_ notification: Notification) {
        if let window {
            Self.rememberContentSize(window.contentRect(forFrameRect: window.frame).size)
        }
        stopTicking()
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--verbose") {
            FileHandle.standardError.write(Data(
                "[pet] manager closed: back to accessory, menu bar hidden\n".utf8
            ))
        }
    }

    /// One second is the resolution of "state ages out", and it also keeps
    /// the relative timestamps and the `showing` marker honest.
    private func startTicking() {
        guard ticker == nil else { return }
        onTick?()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTick?() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }
}
