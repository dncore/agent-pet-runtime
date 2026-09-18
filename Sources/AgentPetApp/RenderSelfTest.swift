import AgentPetCore
import AppKit
import SwiftUI
import Foundation

/// Renders the pet offscreen and measures what actually lands in the buffer.
///
/// `screencapture` cannot see this app's windows without Screen Recording
/// permission, so a pixel count taken from the view's own backing store is the
/// only honest evidence that anything is being drawn. Run with
/// `AgentPet --selftest`.
@MainActor
enum RenderSelfTest {

    struct Result {
        let state: AgentState
        let trackName: String
        let opaquePixels: Int
        let totalPixels: Int
    }

    /// Draws `view` into an offscreen buffer and counts pixels with any alpha.
    static func measure(_ view: PetView) -> (opaque: Int, total: Int) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return (0, 0)
        }
        view.cacheDisplay(in: view.bounds, to: rep)

        guard let data = rep.bitmapData else { return (0, 0) }
        let samplesPerPixel = rep.samplesPerPixel
        guard samplesPerPixel >= 4 else { return (0, 0) }

        var opaque = 0
        let count = rep.pixelsWide * rep.pixelsHigh
        for index in 0..<count {
            // Alpha is the last sample in the RGBA layout AppKit hands back.
            if data[index * samplesPerPixel + 3] > 8 { opaque += 1 }
        }
        return (opaque, count)
    }

    /// A hash of what was actually drawn.
    ///
    /// Comparing renders by opaque-pixel count is not enough — two different
    /// rows can light the same number of pixels, and a count cannot tell a
    /// changed picture from an unchanged one. This compares content.
    static func contentHash(_ view: PetView) -> String {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return "no-rep"
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.bitmapData else { return "no-data" }
        return String(
            Hashing.sha256(Data(bytes: data, count: rep.bytesPerRow * rep.pixelsHigh)).prefix(12)
        )
    }

    /// What one track looks like over time, for comparing tracks against each
    /// other.
    ///
    /// Two samples, because a single one at the start of an animation is not
    /// a fair comparison: packages are commonly authored with the same neutral
    /// pose in column 0 of every row (clippit is), so every track *opens*
    /// identically and only diverges as it plays. The offset is chosen to land
    /// mid-cycle for every row in the contract, whose shortest is about a
    /// second.
    private static func trackSignature(
        _ state: AgentState,
        controller: PetController,
        view: PetView
    ) -> String {
        var samples: [String] = []
        for elapsed in [0.0, 0.42] {
            controller.previewState(state, elapsed: elapsed)
            samples.append(contentHash(view))
        }
        return samples.joined(separator: "+")
    }

    static func run(controller: PetController, view: PetView, petWidth: CGFloat) -> Int32 {
        print("Render self-test")
        print("")

        // With no pet installed there is nothing to render, and that is an
        // environment fact rather than a defect. Reported distinctly so a CI
        // run on a bare machine does not look like a broken build.
        guard controller.loadedProfile != nil else {
            print("  – skipped: no pet packages are installed")
            print("")
            print("SKIPPED")
            return 0
        }

        var failures = 0
        let states: [AgentState] = [.idle, .running, .waitingInput, .waitingApproval,
                                    .completed, .failed, .paused, .unknown]

        // Pinned to no direction for everything compared here: with a pointer
        // on screen the look frame replaces the idle row — checked on its own
        // further down — and two states that render the same pose would
        // compare as one track.
        controller.aimGaze(at: nil)

        // Two states sharing a track must look identical; two states on
        // different tracks must not. Comparing raw state-to-state would flag
        // `waitingInput` and `waitingApproval` as a bug when they are in fact
        // deliberately the same animation.
        var rendersByTrack: [String: (signature: String, states: [AgentState])] = [:]

        for state in states {
            controller.previewState(state)
            guard let image = view.currentImage else {
                print("  ✗ \(state.rawValue): no image")
                failures += 1
                continue
            }

            let (opaque, total) = measure(view)
            let ratio = total > 0 ? Double(opaque) / Double(total) : 0
            let ok = opaque > 0
            if !ok { failures += 1 }

            let track = state.animationTrackName
            print(String(
                format: "  %@ %-16s -> %-9s %4dx%-4d  %6d / %6d visible px  (%.1f%%)",
                ok ? "✓" : "✗",
                (state.rawValue as NSString).utf8String!,
                (track as NSString).utf8String!,
                image.width, image.height,
                opaque, total, ratio * 100
            ))

            let signature = trackSignature(state, controller: controller, view: view)
            if var existing = rendersByTrack[track] {
                if existing.signature != signature {
                    print("      ✗ same track '\(track)' rendered differently for "
                          + "\(existing.states.map(\.rawValue)) and \(state.rawValue)")
                    failures += 1
                }
                existing.states.append(state)
                rendersByTrack[track] = existing
            } else {
                rendersByTrack[track] = (signature, [state])
            }
        }

        // Distinct tracks must produce distinct pictures.
        var seen: [String: String] = [:]
        for (track, entry) in rendersByTrack.sorted(by: { $0.key < $1.key }) {
            if let other = seen[entry.signature] {
                print("  ✗ tracks '\(other)' and '\(track)' render identically")
                failures += 1
            }
            seen[entry.signature] = track
        }

        print("")
        print("  \(rendersByTrack.count) distinct tracks rendered from \(states.count) states")

        failures += checkDraggable(view: view)
        failures += checkBehaviourLayers(controller: controller, view: view)
        failures += checkMessagePanel(controller: controller, view: view, petWidth: petWidth)
        failures += checkReopenedWindow()
        failures += checkManagerSidebar()
        failures += checkSettingsShortcut()

        print("")
        print(failures == 0 ? "PASS" : "FAIL (\(failures) problem(s))")
        return failures == 0 ? 0 : 1
    }

    /// Checks the layers above the agent state — locomotion and gaze — which
    /// the state sweep above never exercises.
    private static func checkBehaviourLayers(controller: PetController, view: PetView) -> Int {
        print("")
        print("Behaviour layers")
        var failures = 0

        // Dragging must take over from whatever the agent is doing.
        controller.previewState(.waitingInput)
        let waitingBefore = view.currentImage
        controller.beginDrag()
        controller.updateDrag(dx: 12, dy: 0)
        let draggedRight = view.currentImage
        if draggedRight != nil, draggedRight !== waitingBefore {
            print("  ✓ dragging replaces the agent state with locomotion")
        } else {
            print("  ✗ dragging did not change the animation")
            failures += 1
        }

        controller.updateDrag(dx: -12, dy: 0)
        if view.currentImage !== draggedRight {
            print("  ✓ reversing the drag switches direction")
        } else {
            print("  ✗ the pet did not turn around when dragged the other way")
            failures += 1
        }

        controller.endDrag()
        controller.clearPreview()
        if view.currentImage !== draggedRight {
            print("  ✓ releasing returns the pet to its own animation")
        } else {
            print("  ✗ the pet stayed in locomotion after the drag ended")
            failures += 1
        }

        // The pointer arriving makes the pet jump — Codex's `hovered ?
        // "jumping" : state` — and the pose it lands in is held until the
        // pointer leaves, so the picture must stay put rather than fall back
        // to the agent's row on its own.
        controller.previewState(.running)
        let workingBefore = view.currentImage
        controller.beginHover()
        let jumped = view.currentImage
        if jumped != nil, jumped !== workingBefore {
            print("  ✓ the pointer arriving plays the jump")
        } else {
            print("  ✗ hovering did not change the animation")
            failures += 1
        }

        // Three passes, and then it breathes: the landing pose is not the end
        // of the story while the pointer stays.
        controller.aimHover(elapsed: 20)   // well past the jump's three passes
        let settledHover = view.currentImage
        controller.aimHover(elapsed: 20.5)
        if settledHover != nil, settledHover !== view.currentImage {
            print("  ✓ a hovered pet keeps animating after the jump, rather than freezing")
        } else {
            print("  ✗ the pet froze on the jump's last frame instead of settling into idle")
            failures += 1
        }
        controller.aimHover(elapsed: nil)

        controller.endHover()
        if view.currentImage !== jumped {
            print("  ✓ the pointer leaving hands the pet back to its own animation")
        } else {
            print("  ✗ the pet stayed on the jump after the pointer left")
            failures += 1
        }
        controller.clearPreview()

        // The introduction: the pet waves and the panel carries the words.
        // Codex shows its own for eight seconds, once per pet.
        //
        // With a direction pinned: the wave is not a row the look frame may
        // replace (2026-09-17), so the hello is a wave even with the pointer
        // on screen — which is the only way an introduction is ever seen.
        controller.aimGaze(at: 90)
        let beforeGreeting = view.currentImage
        controller.introduce(petName: "Clippy")
        let greetingRow = view.currentPanel.rows.first
        let greetingLabel = greetingRow?.message?.label
        let greetingBody = greetingRow?.message?.body
        if greetingLabel == "Hi, I'm Clippy",
           greetingBody == "I'm here to help keep your sessions moving",
           view.currentImage !== beforeGreeting {
            print("  ✓ the pet introduces itself, and waves while it does")
        } else {
            print("  ✗ the introduction is wrong: "
                  + "\(greetingLabel ?? "no row") / \(greetingBody ?? "-")")
            failures += 1
        }
        controller.aimGaze(at: nil)

        // A row that belongs to no session must not invent the columns a
        // session row has: a blank agent name or session id reads as a bug,
        // and the pet's own line has neither.
        if let greetingRow {
            let items = MessagePanelLayout.items(
                for: greetingRow, config: view.currentPanelConfig, petWidth: view.petWidth
            )
            let sessionColumns = items.filter { $0.kind == .agent || $0.kind == .session }
            if sessionColumns.isEmpty {
                print("  ✓ the introduction carries no session's columns")
            } else {
                print("  ✗ the introduction drew a blank agent or session column")
                failures += 1
            }
        }
        // Retired before the panel checks: they count session rows, and the
        // introduction is not one.
        controller.dismissGreeting()

        // Gaze only exists in a V2 atlas. A V1 pet has nowhere to put a
        // direction, so "no effect" is the correct result rather than a fault.
        guard let profile = controller.loadedProfile else {
            controller.clearPreview()
            return failures
        }
        guard profile.hasLookDirections else {
            print("  – gaze skipped: \(profile.displayName) has no look rows "
                  + "(a V2 pet is needed)")
            controller.clearPreview()
            return failures
        }

        // A direction to look in replaces the idle row; taking it away gives
        // the row back. Both ends are pinned here — the direction the real
        // pointer happens to give is not something a test can assert.
        controller.previewState(.idle)
        controller.aimGaze(at: nil)
        let idleFrame = view.currentImage
        controller.aimGaze(at: 90)   // straight right
        if view.currentImage != nil, view.currentImage !== idleFrame {
            print("  ✓ an idle pet turns to look toward the pointer")
        } else {
            print("  ✗ gaze had no effect on a \(profile.displayName) pet")
            failures += 1
        }

        controller.aimGaze(at: nil)
        if view.currentImage === idleFrame {
            print("  ✓ with no direction the pet falls back to its own row")
        } else {
            print("  ✗ the pet did not fall back when the direction went away")
            failures += 1
        }

        // The gaze is folded into the idle fallback alone: a look pose is one
        // static frame, and while it also replaced `running` and `waving`, a
        // working pet was drawn exactly like a resting one and the pet's hello
        // was drawn as a stare (2026-09-17, from use). Rows with something of
        // their own to show keep their row with the pointer anywhere.
        controller.previewState(.running)
        controller.aimGaze(at: 90)
        let workingGazing = view.currentImage
        controller.aimGaze(at: nil)
        if workingGazing != nil, workingGazing === view.currentImage {
            print("  ✓ a working pet keeps running, wherever the pointer is")
        } else {
            print("  ✗ the gaze took the running row away")
            failures += 1
        }

        // With no direction they go back to their own rows.
        controller.aimGaze(at: nil)
        controller.previewState(.running)
        let working = view.currentImage
        controller.previewState(.idle)
        if working !== view.currentImage {
            print("  ✓ with no direction each state plays its own row again")
        } else {
            print("  ✗ running and idle played the same row")
            failures += 1
        }

        // And a waiting pet is not a row Codex replaces, so it keeps asking.
        controller.aimGaze(at: 90)
        controller.previewState(.waitingInput)
        let waitingGazing = view.currentImage
        controller.aimGaze(at: nil)
        controller.previewState(.waitingInput)
        if waitingGazing !== view.currentImage {
            print("  ✗ the gaze replaced a waiting pet's row")
            failures += 1
        } else {
            print("  ✓ a waiting pet keeps asking, whatever the pointer is doing")
        }

        controller.aimGaze(at: nil)
        controller.clearPreview()
        return failures
    }

    /// Verifies the message panel beside the pet: the rows, the space they
    /// reserve, the window that grows for them, and the usage ring.
    ///
    /// Driven by real events through the real engine — the panel is a view of
    /// the activity list, and a test that hand-built the rows would prove
    /// nothing about whether sessions reach it.
    private static func checkMessagePanel(controller: PetController, view: PetView, petWidth: CGFloat) -> Int {
        print("")
        print("Message panel")
        var failures = 0
        let now = Date()
        let confidence = EventConfidence(level: .high, source: "selftest")

        func send(
            _ kind: AgentEventKind, agent: String, session: String, at offset: TimeInterval,
            tool: String? = nil, summary: String? = nil, context: SessionContext? = nil
        ) {
            controller.ingest(AgentEvent(
                agentID: agent,
                sessionID: session,
                kind: kind,
                at: now.addingTimeInterval(offset),
                confidence: confidence,
                summary: summary,
                toolName: tool,
                focusTarget: .openingDirectory(URL(fileURLWithPath: "/tmp/project")),
                context: context
            ))
        }

        // Two agents, one of them blocked — the case the whole panel exists
        // for. The blocked one arrives first so the focus lands on it without
        // waiting out the engine's anti-flicker hold, which is deliberately
        // three seconds long and not something a test should sleep through.
        send(.waitingApproval, agent: "claude-code", session: "cafebabe-2222", at: 0,
             tool: "Write",
             summary: "Claude wants to run git push origin main",
             context: SessionContext(usedPercent: 72, totalTokens: 144_000,
                                     windowSize: 200_000, modelName: "Opus 4.6",
                                     effortLevel: "high", costUSD: 3.42,
                                     fiveHourPercent: 41, sevenDayPercent: 12,
                                     capturedAt: now))
        send(.working, agent: "codex", session: "deadbeef-1111", at: 1, tool: "Bash")

        let panel = view.currentPanel
        guard panel.rows.count == 2 else {
            print("  ✗ expected a row per session, got \(panel.rows.count)")
            controller.resetActivities()
            return failures + 1
        }
        print("  ✓ \(panel.rows.count) sessions, one row each")

        // The blocked session is the one whose row is marked as being shown.
        if let focused = panel.rows.first(where: { $0.isFocused }),
           focused.agentName == "Claude Code" {
            print("  ✓ the blocked session is the row the pet is showing")
        } else {
            print("  ✗ the wrong session is marked as shown")
            failures += 1
        }

        let claude = panel.rows.first { $0.agentID == "claude-code" }
        if claude?.sessionSuffix == "e-2222", claude?.message?.label == "Needs input",
           claude?.context?.usedPercent == 72, claude?.task == "project" {
            print("  ✓ the row carries the session suffix, wording, context, and project")
        } else {
            print("  ✗ row contents are wrong: "
                  + "\(claude.map { "\($0.sessionSuffix) / \($0.message?.label ?? "-") / \($0.task ?? "-")" } ?? "missing")")
            failures += 1
        }

        // A tool is only "current" while the session is working.
        let codex = panel.rows.first { $0.agentID == "codex" }
        if codex?.tool == "Bash", claude?.tool == nil {
            print("  ✓ the tool is shown while working, and dropped when blocked")
        } else {
            print("  ✗ tool visibility is wrong")
            failures += 1
        }

        // Positions and sizes, as the window sees them. The app's own config,
        // not the view's: the view's copy is whatever this test last handed it,
        // and the restore lines below would restore to a mutated config.
        let appPanelConfig = controller.panelConfig()
        let plan = MessagePanelLayout.plan(for: panel, config: appPanelConfig, petWidth: petWidth)
        let pet = PetWindow.size(forWidth: petWidth)
        let configuredWidth = plan.width
        let withPanel = contentHash(view)
        if plan.height > 0, view.spriteRect.height < view.bounds.height {
            print("  ✓ the pet keeps its place: \(Int(plan.height))pt reserved above it")
        } else {
            print("  ✗ the panel was drawn over the pet instead of beside it")
            failures += 1
        }

        if let window = view.window,
           abs(window.frame.height - (pet.height + plan.height)) < 1,
           abs(window.frame.width - configuredWidth) < 1 {
            print("  ✓ the window is \(Int(window.frame.width))x\(Int(window.frame.height)) "
                  + "— the width the panel's content asks for, or the settings' maximum")
        } else {
            print("  ✗ the window is wrong: "
                  + "\(view.window.map { "\($0.frame.width)x\($0.frame.height)" } ?? "no window") "
                  + "wanting \(configuredWidth) wide")
            failures += 1
        }

        // The gaze has to be aimed from the sprite, not from the window: the
        // panel lives inside the window, so the window's centre is above the
        // pet by half the panel's height and the pose it resolves would be a
        // neighbour of the right one. Checked here, with a panel up, because
        // with no panel the two centres are the same point and nothing is
        // being asked of the provider.
        let spriteCentre = view.convert(
            CGPoint(x: view.spriteRect.midX, y: view.spriteRect.midY), to: nil
        )
        if let window = view.window, plan.height > 0,
           let aim = controller.petCenterProvider?() {
            let want = window.convertPoint(toScreen: spriteCentre)
            let drift = abs(aim.x - want.x) + abs(aim.y - want.y)
            // Screen y grows upward, so the panel puts the window's centre
            // *above* the sprite's.
            let reserved = window.frame.midY - aim.y
            if drift < 0.5, reserved > 1 {
                print("  ✓ the gaze aims from the sprite's centre, "
                      + "\(Int(reserved))pt below the window's own")
            } else {
                print("  ✗ the gaze aims from \(aim), the sprite's centre is \(want)")
                failures += 1
            }
        } else {
            print("  ✗ no panel, no window, or no gaze origin to check")
            failures += 1
        }

        // The width setting is a percentage of the pet — and the *maximum*
        // the panel may be drawn at, not necessarily its width.
        var narrow = MessagePanelConfig()   // the panel's own defaults, not the app's config
        narrow.widthPercent = 110
        narrow.autoScale = false
        narrow.fitsText = false
        var narrowAtDefaultText = narrow
        narrowAtDefaultText.messageFontSize = MessagePanelConfig.defaultFontSize
        let narrowWidth = MessagePanelLayout.maximumPanelWidth(
            for: narrowAtDefaultText, petWidth: pet.width
        )
        let narrowedZoom = MessagePanelLayout.maximumPanelWidth(for: narrow, petWidth: pet.width)
        let zoom = CGFloat(MessagePanelConfig.clampFontSize(narrow.messageFontSize)
                           / MessagePanelConfig.defaultFontSize)
        if abs(narrowWidth - pet.width * 1.1) <= 1,
           abs(narrowedZoom - narrowWidth * zoom) <= 1 {
            print("  ✓ the width setting is a percentage of the pet: 110% → \(Int(narrowWidth))pt "
                  + "at the default text size, \(Int(narrowedZoom))pt at \(narrow.messageFontSize)pt")
        } else {
            print("  ✗ the width setting does not follow the pet's width")
            failures += 1
        }

        // Scaling with the pet overrides both manual settings: the text draws
        // at the default size for that pet, and the width asks for the default
        // percentage of it, whatever the sliders happen to say.
        var auto = narrow
        auto.autoScale = true
        auto.messageFontSize = MessagePanelConfig.maximumFontSize
        auto.widthPercent = MessagePanelConfig.maximumWidthPercent
        let autoMetrics = MessagePanelLayout.metrics(for: auto, petWidth: 224)
        let autoMaximum = MessagePanelLayout.maximumPanelWidth(for: auto, petWidth: 224)
        if abs(autoMetrics.messageFont.pointSize - 21) < 0.01,
           abs(autoMetrics.itemFont.pointSize - 21) < 0.01,
           abs(autoMaximum - 448) <= 1 {
            print("  ✓ scaling with the pet ignores the sliders: a 224pt pet draws 21pt text "
                  + "in a panel of up to \(Int(autoMaximum))pt")
        } else {
            print("  ✗ scaling with the pet did not override the manual settings: "
                  + "\(autoMetrics.itemFont.pointSize)pt text, \(Int(autoMaximum))pt wide")
            failures += 1
        }

        // `alignment` is where the panel sits relative to the pet, not how the
        // text inside it is set: the pet sits at the window's left edge for
        // `.left`, at its right edge for `.right`, and the text does not move
        // at all.
        var anchoredLeft = appPanelConfig
        anchoredLeft.alignment = .left
        view.show(panel, config: anchoredLeft)
        let leftSprite = view.spriteRect
        var anchoredRight = anchoredLeft
        anchoredRight.alignment = .right
        view.show(panel, config: anchoredRight)
        let rightSprite = view.spriteRect
        view.show(panel, config: appPanelConfig)

        func itemOrigins(_ config: MessagePanelConfig) -> [CGFloat] {
            let plan = MessagePanelLayout.plan(for: panel, config: config, petWidth: petWidth)
            guard let row = plan.rows.first else { return [] }
            return MessagePanelLayout.frames(for: row, columns: plan.columns, metrics: plan.metrics)
                .map(\.frame.minX)
        }
        let roomToAnchor = view.bounds.width > petWidth + 0.5
        if itemOrigins(anchoredLeft) != itemOrigins(anchoredRight) {
            print("  ✗ the alignment moved the text instead of the panel: "
                  + "items at \(itemOrigins(anchoredLeft)) then \(itemOrigins(anchoredRight))")
            failures += 1
        } else if !roomToAnchor {
            // A panel no wider than the pet has no anchor to show: the pet
            // fills the window whatever the setting says.
            print("  – alignment skipped: this panel is no wider than the pet")
        } else if leftSprite.minX == view.bounds.minX,
                  abs(rightSprite.minX - (view.bounds.width - petWidth)) < 0.5,
                  rightSprite.minX > leftSprite.minX {
            print("  ✓ the alignment anchors the panel to the pet — the sprite at the window's "
                  + "left edge for .left, its right edge for .right — and the text inside "
                  + "does not move")
        } else {
            print("  ✗ the panel is not anchored to the pet: sprite at "
                  + "\(leftSprite.minX)/\(rightSprite.minX) in a \(Int(view.bounds.width))pt window")
            failures += 1
        }

        // One set of columns for every row: the same kind is drawn at the same
        // x in each, whether or not the row before it carried that item.
        let columnPlan = MessagePanelLayout.plan(for: panel, config: MessagePanelConfig(),
                                                 petWidth: petWidth)
        var originsByKind: [MessagePanelConfig.Kind: Set<CGFloat>] = [:]
        var cells = 0
        for row in columnPlan.rows {
            for (item, frame) in MessagePanelLayout.frames(
                for: row, columns: columnPlan.columns, metrics: columnPlan.metrics
            ) {
                originsByKind[item.kind, default: []].insert(frame.minX)
                cells += 1
            }
        }
        let sharedOrigins = originsByKind.values.allSatisfy { $0.count == 1 }
            && originsByKind.count >= 4
        if columnPlan.rows.count >= 2, sharedOrigins {
            print("  ✓ every row is laid out on the same columns: "
                  + "\(originsByKind.count) columns, \(cells) cells, each kind at one x")
        } else {
            print("  ✗ the rows do not share their columns: "
                  + originsByKind.map { "\($0.key.rawValue) at \($0.value.sorted())" }.joined(separator: ", "))
            failures += 1
        }

        // The message's own column is never narrower than its wording plus the
        // room for a detail — and a row that has no tool does not shift its
        // message to the left of a row that has one.
        if let messageColumn = columnPlan.columns.first(where: { $0.kind == .message }) {
            let widestWording = columnPlan.rows
                .compactMap { $0.items.first { $0.kind == .message } }
                .map { MessagePanelLayout.width(of: $0.primary + "…",
                                                font: columnPlan.metrics.messageFont) }
                .max() ?? 0
            let allowance = columnPlan.metrics.messageDetailAllowance
            if messageColumn.fitWidth + 0.5 >= widestWording + allowance {
                print("  ✓ the panel is sized for the wording plus \(Int(allowance))pt of detail "
                      + "(\(Int(messageColumn.fitWidth))pt), not for a 200-character message")
            } else {
                print("  ✗ the message column is sized for \(Int(messageColumn.fitWidth))pt, "
                      + "wanting \(Int(widestWording + allowance))pt")
                failures += 1
            }
        } else {
            print("  ✗ the panel has no message column")
            failures += 1
        }

        // Fitting itself to the content: a panel with one short item is
        // narrower than its maximum and never narrower than the pet; one whose
        // content needs the room stays at the maximum.
        var sparse = appPanelConfig
        sparse.items = [MessagePanelConfig.Item(.message)]
        sparse.fitsText = true
        // Wide enough that the content is what decides the width, whatever the
        // app's own setting happens to be.
        sparse.widthPercent = MessagePanelConfig.maximumWidthPercent
        let sparsePlan = MessagePanelLayout.plan(for: panel, config: sparse, petWidth: petWidth)
        var whole = sparse
        whole.fitsText = false
        let wholePlan = MessagePanelLayout.plan(for: panel, config: whole, petWidth: petWidth)
        // One glyph and nothing else is narrower than the pet, and the panel
        // is not allowed to be: it is the thing the pet is sitting under.
        var tiny = sparse
        tiny.items = [MessagePanelConfig.Item(.agent)]
        let tinyPlan = MessagePanelLayout.plan(for: panel, config: tiny, petWidth: petWidth)
        let maximum = MessagePanelLayout.maximumPanelWidth(for: sparse, petWidth: petWidth)
        let fitHasRoom = maximum > petWidth + 0.5
        if (!fitHasRoom || sparsePlan.width < maximum), wholePlan.width == maximum,
           tinyPlan.width == petWidth {
            print("  ✓ the panel fits itself to its content: \(Int(sparsePlan.width))pt for one "
                  + "message item, \(Int(wholePlan.width))pt (the maximum) with the fit off, and "
                  + "the pet's own \(Int(petWidth))pt for a single glyph"
                  + (fitHasRoom ? "" : " — the maximum is the pet, so there is no room to hug"))
        } else {
            print("  ✗ the fit did not follow the content: \(Int(sparsePlan.width))pt fitted, "
                  + "\(Int(wholePlan.width))pt asked, \(Int(tinyPlan.width))pt for one glyph, "
                  + "maximum \(Int(maximum))pt")
            failures += 1
        }

        // The context item is only drawn when a status line has reported one:
        // taking it away must change the picture.
        var withoutContext = appPanelConfig
        if let index = withoutContext.items.firstIndex(where: { $0.kind == .context }) {
            withoutContext.items[index].isEnabled = false
        }
        view.show(panel, config: withoutContext)
        let withoutContextHash = contentHash(view)
        view.show(panel, config: appPanelConfig)
        if !appPanelConfig.items.contains(where: { $0.kind == .context && $0.isEnabled }) {
            print("  – usage ring skipped: this config has the context item switched off")
        } else if withoutContextHash != withPanel {
            print("  ✓ the usage ring is actually painted")
        } else {
            print("  ✗ turning the context item off changed nothing")
            failures += 1
        }

        // Neither mark leaves the column it was given — the ring inside the
        // column, the digits inside the ring — at any width the settings
        // allow. The bar this replaced did neither: it was drawn at the
        // metrics' own width whatever the column had been squeezed to, and its
        // column's floor was half a *label's* minimum, a number with nothing to
        // do with a bar, so on a narrow panel it ran straight under the status
        // wording beside it (user report, 2026-09-20). Read here as rectangles,
        // because that is the whole of the bug: the ring is painted, and the
        // next item starts where the column ends.
        var escapes: [String] = []
        var ringsLookedAt = 0
        var digitsLookedAt = 0
        let crowded = MessagePanelConfig()   // every item on
        var roomy = MessagePanelConfig()     // and a row with room to spare
        roomy.items = [.session, .context, .message].map { MessagePanelConfig.Item($0) }
        for (name, config) in [("the full row", crowded), ("a roomy row", roomy)] {
            for percent in stride(from: MessagePanelConfig.minimumWidthPercent,
                                  through: MessagePanelConfig.maximumWidthPercent, by: 20) {
                var tight = config
                tight.widthPercent = percent
                tight.fitsText = false
                let tightPlan = MessagePanelLayout.plan(for: panel, config: tight,
                                                        petWidth: petWidth)
                for row in tightPlan.rows {
                    for (item, frame) in MessagePanelLayout.frames(
                        for: row, columns: tightPlan.columns, metrics: tightPlan.metrics
                    ) where item.kind == .context {
                        // Only the badge is read here. An item with no badge is
                        // a token count, which is text in the column it was
                        // given and truncates in it, as it always has.
                        let marks = MessagePanelLayout.usageLayout(
                            item, in: frame, metrics: tightPlan.metrics
                        )
                        guard let ring = marks.ring else { continue }
                        ringsLookedAt += 1
                        if ring.minX < frame.minX - 0.5 || ring.maxX > frame.maxX + 0.5
                            || ring.width > tightPlan.metrics.contextRingDiameter + 0.5 {
                            escapes.append("a \(Int(ring.width))pt ring in a "
                                           + "\(Int(frame.width))pt column at "
                                           + "\(Int(percent))% in \(name)")
                        }
                        // The digits' rect is the ring's hole by construction,
                        // so what is checked is the thing that decision is for:
                        // that the ink a percentage can produce — three digits,
                        // "100" being the widest — is inside the hole and not
                        // through the stroke. The rule itself lives in the
                        // layout (`badgeInkFault`); it is asked here with the
                        // ring the layout actually handed out, which is the same
                        // hole by construction, but asked over every (config,
                        // width) pair this sweep covers.
                        //
                        // Asking the layout's own rule is how this check stopped
                        // reporting a failure at the default pet for a badge
                        // that draws correctly: measured by hand, the line box's
                        // diagonal is 13.3pt against a 13pt hole while the ink's
                        // is 10.6pt at the ratio this first ran at, 14.4 and
                        // 11.9 at the 0.62 it ships with. The line box is never
                        // the question — digits have no descenders, so empty
                        // line height outside the hole draws nothing.
                        if marks.digits != nil {
                            digitsLookedAt += 1
                            if let why = MessagePanelLayout.badgeInkFault(
                                of: ring, metrics: tightPlan.metrics
                            ) {
                                escapes.append("\(why) at \(Int(percent))% in \(name)")
                            }
                        }
                    }
                }
            }
        }

        // And at every scale the pet can be set to, because the badge is one
        // drawing at one scale and the fit above is a ratio: at twice the pet
        // the hole is twice as wide, but the digits are twice as tall too.
        var holeAtTheSmallest: CGFloat = 0
        for width in [CGFloat(AppConfig.PetConfig.minimumWidth), 112, 168, 224] {
            var scaleConfig = MessagePanelConfig()
            scaleConfig.messageFontSize = MessagePanelConfig.defaultFontSize
            let metrics = MessagePanelLayout.metrics(for: scaleConfig, petWidth: width)
            if holeAtTheSmallest == 0 {
                holeAtTheSmallest = metrics.contextRingDiameter
                    - 2 * metrics.contextRingLineWidth
            }
            if let why = MessagePanelLayout.badgeInkFault(of: nil, metrics: metrics) {
                escapes.append("\(why) at a \(Int(width))pt pet")
            }
        }

        if escapes.isEmpty, ringsLookedAt > 0, digitsLookedAt > 0 {
            let atDefault = MessagePanelLayout.metrics(for: MessagePanelConfig(), petWidth: 112)
            print("  ✓ the badge stays in its own column — \(ringsLookedAt) rings, "
                  + "\(digitsLookedAt) of them with the reading inside, over "
                  + "\(Int(MessagePanelConfig.minimumWidthPercent))–"
                  + "\(Int(MessagePanelConfig.maximumWidthPercent))% of the pet — and \"100\", the "
                  + "widest reading there is, fits its hole at every Pet → Size "
                  + "(\(String(format: "%.1f", holeAtTheSmallest))pt hole at the smallest pet for "
                  + "\(String(format: "%.1f", atDefault.contextRingFont.pointSize))pt digits "
                  + "against \(String(format: "%.1f", atDefault.itemFont.pointSize))pt text)")
        } else if !escapes.isEmpty {
            print("  ✗ the usage figure is drawn outside its own column: "
                  + escapes.prefix(4).joined(separator: "; "))
            failures += 1
        } else if ringsLookedAt == 0 || digitsLookedAt == 0 {
            print("  ✗ no usage badge was laid out at any width — this check proves nothing")
            failures += 1
        }

        // Temporary: a PNG of what is actually drawn, for looking at.
        //
        // Dumped with the app's own config rather than the one this test last
        // handed the view, which is not what the user has on screen.
        if let path = ProcessInfo.processInfo.environment["AGENTPET_DUMP_PANEL"],
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.show(panel, config: controller.panelConfig())
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: path))
            print("  – panel dumped to \(path) (\(Int(view.bounds.width))x\(Int(view.bounds.height)))")
        }

        // The agent column is a glyph, not a name: "Claude Code" would take
        // most of the panel's width, and the name is what the Agents page is
        // for. The name stays on the item for the verbose log — so the column
        // is the width of the glyph, whatever the scale, and never the width
        // of the name.
        let agentItems = MessagePanelLayout.items(
            for: panel.rows[0], config: appPanelConfig, petWidth: petWidth
        ).filter { $0.kind == .agent }
        let glyphWidth = MessagePanelLayout.metrics(
            for: appPanelConfig, petWidth: petWidth
        ).iconItemWidth
        if agentItems.isEmpty {
            print("  – agent glyph skipped: this config has the agent item switched off")
        } else if let agent = agentItems.first,
           let symbol = agent.symbolName,
           NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
           abs(agent.width - glyphWidth) < 0.5,
           !agent.primary.isEmpty {
            print("  ✓ the agent column is the glyph '\(symbol)' — \(Int(agent.width))pt, for '\(agent.primary)'")
        } else {
            print("  ✗ the agent column is not an icon")
            failures += 1
        }

        // And it has to survive the row's squeeze. A panel narrower than its
        // items drops what it cannot fit — anything under half the minimum
        // item width — and a thirteen-point glyph used to be dropped as "too
        // narrow to say anything", which made the whole column vanish while
        // the item list still looked right.
        let fullConfig = MessagePanelConfig()   // every item on, 200% of the pet
        let fullPlan = MessagePanelLayout.plan(for: panel, config: fullConfig, petWidth: pet.width)
        let drawnKinds = fullPlan.rows.first.map {
            MessagePanelLayout.frames(for: $0, columns: fullPlan.columns, metrics: fullPlan.metrics)
                .map(\.item.kind)
        } ?? []
        if drawnKinds.contains(.agent) {
            print("  ✓ it survives a row too narrow for everything else (\(drawnKinds.count) of 9 items fit)")
        } else {
            print("  ✗ the agent glyph was squeezed out of the row entirely")
            failures += 1
        }

        // The message line follows the pet; nothing else follows the message,
        // and in particular the width does not. The default has to stay
        // exactly what it has always been — 10.5pt in an 18pt row — or the
        // panel would move for every existing user the moment they upgrade.
        let baseMetrics = MessagePanelLayout.metrics(for: fullConfig, petWidth: 112)
        let bigMetrics = MessagePanelLayout.metrics(for: fullConfig, petWidth: 224)
        var largeText = fullConfig
        largeText.messageFontSize = 20
        let wideMetrics = MessagePanelLayout.metrics(for: largeText, petWidth: 112)
        if abs(baseMetrics.messageFont.pointSize - 10.5) < 0.01, baseMetrics.rowHeight == 18 {
            print("  ✓ at the default pet the message is still 10.5pt in an 18pt row")
        } else {
            print("  ✗ the default message size moved: "
                  + "\(baseMetrics.messageFont.pointSize)pt, row \(baseMetrics.rowHeight)")
            failures += 1
        }
        let baseWidth = MessagePanelLayout.maximumPanelWidth(for: fullConfig, petWidth: 112)
        let wideTextWidth = MessagePanelLayout.maximumPanelWidth(for: largeText, petWidth: 112)
        if abs(bigMetrics.messageFont.pointSize - 21) < 0.01, abs(bigMetrics.rowHeight - 36) <= 1,
           abs(wideMetrics.messageFont.pointSize - 20) < 0.01,
           abs(wideTextWidth - baseWidth * wideMetrics.scale) <= 1 {
            print("  ✓ a 224pt pet draws the message at 21pt — and the panel is one drawing at any "
                  + "scale: 200% of the default pet is \(Int(baseWidth))pt, the same 200% at 20pt is "
                  + "\(Int(wideTextWidth))pt")
        } else {
            print("  ✗ the panel does not scale as one piece: "
                  + "\(wideMetrics.messageFont.pointSize)pt text in a \(wideTextWidth)pt panel, "
                  + "wanting \(Int(baseWidth * wideMetrics.scale))pt")
            failures += 1
        }

        // And the whole row is at that scale — not just the message's font.
        // The message alone used to follow the pet, which left two sizes side
        // by side in one row: at 20pt the status wording sat beside a 10.5pt
        // task name, a 13pt glyph and a 7pt bar, and raising the pet made the
        // rest of the row relatively smaller still. Every number the panel
        // draws with now moves with the scale, so what a bigger pet buys is a
        // bigger panel, not a bigger message.
        let scaledWithThePet: [(String, CGFloat, CGFloat)] = [
            ("the other labels", baseMetrics.itemFont.pointSize, bigMetrics.itemFont.pointSize),
            ("the agent's label", baseMetrics.agentFont.pointSize, bigMetrics.agentFont.pointSize),
            ("the session id", baseMetrics.sessionFont.pointSize, bigMetrics.sessionFont.pointSize),
            ("the row", baseMetrics.rowHeight, bigMetrics.rowHeight),
            ("the padding", baseMetrics.padding, bigMetrics.padding),
            ("the item gap", baseMetrics.spacing, bigMetrics.spacing),
            ("the agent glyph", baseMetrics.iconItemWidth, bigMetrics.iconItemWidth),
            ("the usage badge", baseMetrics.contextRingDiameter, bigMetrics.contextRingDiameter),
            ("the panel", MessagePanelLayout.maximumPanelWidth(for: fullConfig, petWidth: 112),
             MessagePanelLayout.maximumPanelWidth(for: fullConfig, petWidth: 224)),
        ]
        if let (name, one, two) = scaledWithThePet.first(where: { abs($0.2 - 2 * $0.1) > 0.01 }) {
            print("  ✗ \(name) did not double with the pet: \(one) -> \(two)")
            failures += 1
        } else {
            print("  ✓ at twice the pet the whole row is twice the size — "
                  + "\(Int(bigMetrics.rowHeight))pt row, \(Int(bigMetrics.itemFont.pointSize))pt labels, "
                  + "\(Int(bigMetrics.contextRingDiameter))pt usage ring, "
                  + "\(Int(bigMetrics.contextRingLineWidth))pt of stroke")
        }

        // And the badge's own numbers, because they are what the request was
        // about: **Pet → Size** has to move the ring's diameter, its stroke and
        // its digits *together*, or a bigger pet draws a hairline ring around a
        // number that did not grow with it — the same two-panels-in-one-row
        // fault the row above was fixed for. (The bar this replaced scaled as a
        // whole too, 46×7pt by the same factor; what it failed at was staying
        // inside the column it was handed, not following the pet.)
        let ringWithThePet: [(String, CGFloat, CGFloat)] = [
            ("diameter", baseMetrics.contextRingDiameter, bigMetrics.contextRingDiameter),
            ("stroke", baseMetrics.contextRingLineWidth, bigMetrics.contextRingLineWidth),
            ("digits", baseMetrics.contextRingFont.pointSize,
             bigMetrics.contextRingFont.pointSize),
        ]
        if let (name, one, two) = ringWithThePet.first(where: { abs($0.2 - 2 * $0.1) > 0.01 }) {
            print("  ✗ the badge's \(name) did not double with the pet: \(one) -> \(two)")
            failures += 1
        } else {
            print("  ✓ the badge follows **Pet → Size**: a "
                  + "\(String(format: "%.0f", baseMetrics.contextRingDiameter))pt ring in "
                  + "\(String(format: "%.0f", baseMetrics.contextRingLineWidth))pt of stroke with "
                  + "\(String(format: "%.1f", baseMetrics.contextRingFont.pointSize))pt digits at a "
                  + "112pt pet, twice all three at 224pt")
        }

        // The status wording survives the largest text size the settings
        // allow. The message column is squeezed like any other column, and it
        // was the one that lost: at 20pt on a 112pt pet, in a row that also
        // carried a task and a context bar, it came back "Needs inpu…" —
        // *less* of the status wording than the same row drew at 10.5pt. A
        // wording cut mid-word says no more than the label it cut, so the
        // squeeze keeps the message column the width of the widest label, plus
        // the ellipsis that marks the detail as cut, and takes the room out of
        // the columns that only name things. Checked with the fit off, so the
        // maximum always binds and the squeeze is always what is being read.
        var wordingConfig = fullConfig
        wordingConfig.messageFontSize = MessagePanelConfig.maximumFontSize
        wordingConfig.widthPercent = 255
        wordingConfig.fitsText = false
        wordingConfig.items = [.agent, .task, .tool, .context, .message]
            .map { MessagePanelConfig.Item($0) }
        let wordingPlan = MessagePanelLayout.plan(for: panel, config: wordingConfig,
                                                  petWidth: pet.width)
        let messageColumn = wordingPlan.columns.first { $0.kind == .message }
        let choppedWording = wordingPlan.rows.compactMap { row -> String? in
            guard let cell = row.items.first(where: { $0.kind == .message }) else { return nil }
            guard let column = messageColumn, column.isDrawn else {
                return "\(row.id)'s message column was dropped entirely"
            }
            // A message with a detail is drawn as "label — detail" and is cut
            // at the end, so the label needs its own width plus the ellipsis;
            // one with nothing but its wording is drawn as it is, and needs
            // only the width it actually has.
            let wording = cell.secondary == nil ? cell.primary : cell.primary + "…"
            let needed = MessagePanelLayout.width(of: wording, font: wordingPlan.metrics.messageFont)
            guard column.width + 0.5 < needed else { return nil }
            return "\(row.id)'s column got \(Int(column.width))pt for a \(Int(needed))pt wording"
        }
        if choppedWording.isEmpty {
            print("  ✓ at the largest text size the status wording is drawn whole")
        } else {
            print("  ✗ the status wording is cut mid-word at the largest text size: "
                  + choppedWording.joined(separator: "; "))
            failures += 1
        }

        // The row fills the panel it was given. A panel wider than what the
        // columns *want* — the fit off, so it is the settings' maximum, with a
        // glyph and a message in it — used to leave the surplus as a hole at
        // the right of every row, which reads as a panel that did not bother
        // to fill itself (user report, 2026-09-18). The message's detail is
        // what closes it: a name is a name whatever its column's width, while
        // the preview under a wording shows more of the message.
        var fillConfig = MessagePanelConfig()
        fillConfig.widthPercent = MessagePanelConfig.maximumWidthPercent
        fillConfig.fitsText = false
        fillConfig.items = [.agent, .message].map { MessagePanelConfig.Item($0) }
        let fillPlan = MessagePanelLayout.plan(for: panel, config: fillConfig, petWidth: petWidth)
        let fillGaps = fillPlan.metrics.spacing * CGFloat(max(0, fillPlan.columns.count - 1))
        let fillDrawn = fillPlan.columns.filter(\.isDrawn).map(\.width).reduce(0, +)
        let spare = fillPlan.width - (fillPlan.metrics.padding * 2 + fillGaps + fillDrawn)
        // A row with no detail does not reserve room for one: the fit follows
        // the detail that is there, up to the allowance. Reserving all of it
        // whatever the message says is what left a "Running" row with a hole
        // after it.
        let codexMessage = panel.rows.first { $0.agentID == "codex" }.flatMap { row in
            MessagePanelLayout.items(for: row, config: fillConfig, petWidth: petWidth)
                .first { $0.kind == .message }
        }
        if let codexMessage {
            let wording = MessagePanelLayout.width(
                of: codexMessage.primary + "…", font: fillPlan.metrics.messageFont
            )
            if abs(codexMessage.fitWidth - wording) < 0.5 {
                print("  ✓ a message with no detail is sized for its wording alone "
                      + "(\(Int(wording))pt), not for the \(Int(fillPlan.metrics.messageDetailAllowance))pt "
                      + "allowance it has nothing to put in")
            } else {
                print("  ✗ a detail-less message reserves \(Int(codexMessage.fitWidth))pt against a "
                      + "\(Int(wording))pt wording")
                failures += 1
            }
        }

        // A second case with room to spare in earnest — two columns in a
        // 300%-wide panel — so that *where* the surplus goes is checked too: it
        // is spread over the columns by their share, not piled into the last
        // one or left at the right.
        var spreadConfig = fillConfig
        spreadConfig.items = [.agent, .task].map { MessagePanelConfig.Item($0) }
        let spreadPlan = MessagePanelLayout.plan(for: panel, config: spreadConfig, petWidth: petWidth)
        let spreadAgent = spreadPlan.columns.first { $0.kind == .agent }?.width ?? 0
        let glyph = spreadPlan.metrics.iconItemWidth
        let spreadGaps = spreadPlan.metrics.spacing
            * CGFloat(max(0, spreadPlan.columns.count - 1))
        let spreadDrawn = spreadPlan.columns.filter(\.isDrawn).map(\.width).reduce(0, +)
        let spreadSpare = spreadPlan.width
            - (spreadPlan.metrics.padding * 2 + spreadGaps + spreadDrawn)
        if spare <= 0.5, spreadSpare <= 0.5, spreadAgent > glyph + 0.5 {
            print("  ✓ the row fills the panel — \(Int(fillDrawn))pt of columns and "
                  + "\(Int(fillGaps))pt of gaps in \(Int(fillPlan.width))pt — and the room "
                  + "is spread over the columns (\(Int(spreadAgent))pt of column for a "
                  + "\(Int(glyph))pt glyph)")
        } else {
            print("  ✗ \(Int(spare))pt of the panel's \(Int(fillPlan.width))pt is left blank "
                  + "at the right of every row (and \(Int(spreadSpare))pt with two columns, "
                  + "agent column \(Int(spreadAgent))pt for a \(Int(glyph))pt glyph)")
            failures += 1
        }

        // Widening the panel restores the task's whole name before it feeds the
        // message's detail. The row gives up the preview under a status wording
        // first, then the columns that only name things, and only then the
        // task's name: taking it from the flexible columns in list order is
        // what left the task as "proj…" while every extra point went to the
        // detail (user report, 2026-09-18).
        var priorityConfig = MessagePanelConfig()
        priorityConfig.messageFontSize = 12
        priorityConfig.widthPercent = 255
        priorityConfig.fitsText = false
        priorityConfig.items = [.agent, .task, .tool, .context, .message]
            .map { MessagePanelConfig.Item($0) }
        let priorityPlan = MessagePanelLayout.plan(for: panel, config: priorityConfig,
                                                   petWidth: 112)
        let cutTasks = priorityPlan.rows.compactMap { row -> String? in
            guard let cell = row.items.first(where: { $0.kind == .task }),
                  let column = priorityPlan.columns.first(where: { $0.kind == .task })
            else { return nil }
            return column.width + 0.5 >= cell.fitWidth ? nil
                : "\(row.id)'s task got \(Int(column.width))pt for a \(Int(cell.fitWidth))pt name"
        }
        if cutTasks.isEmpty {
            print("  ✓ a squeezed panel keeps the task's whole name — the message's detail "
                  + "is what gives way first")
        } else {
            print("  ✗ the task was cut while the message kept its detail: "
                  + cutTasks.joined(separator: "; "))
            failures += 1
        }

        // The other status-line items draw from the same reading. They get a
        // row with room for them: at Codex's pet size a panel carrying every
        // item is full edge to edge, and an item squeezed out entirely would
        // make "turning it off changed nothing" the wrong verdict.
        var statusItems = MessagePanelConfig()
        statusItems.items = [MessagePanelConfig.Item(.session), MessagePanelConfig.Item(.model),
                             MessagePanelConfig.Item(.cost), MessagePanelConfig.Item(.limits)]
        view.show(panel, config: statusItems)
        let withStatusHash = contentHash(view)

        var withoutStatusItems = statusItems
        for index in withoutStatusItems.items.indices
        where [.model, .cost, .limits].contains(withoutStatusItems.items[index].kind) {
            withoutStatusItems.items[index].isEnabled = false
        }
        view.show(panel, config: withoutStatusItems)
        let withoutModelHash = contentHash(view)
        view.show(panel, config: appPanelConfig)
        if withoutModelHash != withStatusHash {
            print("  ✓ the model, cost, and rate-limit items are painted too")
        } else {
            print("  ✗ the model / cost / limits items made no difference")
            failures += 1
        }

        // And an empty panel must give the space back.
        controller.resetActivities()
        let cleared = contentHash(view)
        if cleared != withPanel, view.spriteRect.height == view.bounds.height {
            print("  ✓ clearing the sessions takes the panel down")
        } else {
            print("  ✗ the panel outlived its sessions")
            failures += 1
        }

        // A session that reports tokens without a window size has no fraction
        // to gauge, so its cell is a plain token count — and it shares the
        // context *column* with the rows that do draw a badge. A column takes
        // the widest floor of the cells in it, so a token cell whose floor sits
        // above its own claim drops the whole column and takes those badges
        // with it (measured: 38 of 350 sampled configurations, none of them
        // before the badge replaced the bar, whose cell asked for more than the
        // general floor on its own). At the smallest pet the claim of "999" is
        // under the general floor, which is what makes this the case that
        // breaks.
        controller.resetActivities()
        send(.working, agent: "claude-code", session: "cafebabe-8888", at: 20,
             context: SessionContext(usedPercent: 72, capturedAt: now))
        send(.working, agent: "codex", session: "deadbeef-9999", at: 21, tool: "Bash",
             context: SessionContext(totalTokens: 999, capturedAt: now))
        var mixedConfig = MessagePanelConfig()
        mixedConfig.items = [.session, .context, .message].map { MessagePanelConfig.Item($0) }
        mixedConfig.widthPercent = MessagePanelConfig.minimumWidthPercent
        let mixedPet = CGFloat(AppConfig.PetConfig.minimumWidth)
        let mixedPlan = MessagePanelLayout.plan(for: view.currentPanel, config: mixedConfig,
                                               petWidth: mixedPet)
        var badgeRows = 0
        var tokenRows = 0
        var drawn = 0
        for row in mixedPlan.rows {
            for (item, frame) in MessagePanelLayout.frames(
                for: row, columns: mixedPlan.columns, metrics: mixedPlan.metrics
            ) where item.kind == .context {
                drawn += 1
                if MessagePanelLayout.usageLayout(item, in: frame, metrics: mixedPlan.metrics)
                    .ring != nil {
                    badgeRows += 1
                } else {
                    tokenRows += 1
                }
            }
        }
        // The column itself is where the defect showed: a floor above the
        // widest claim in it means the column is not drawn at all
        // (`Column.isDrawn`), and the cells above would simply not be there to
        // count — which is why the check belongs here and not per cell: a
        // per-cell form ("this item floors above its own claim") cannot fire
        // once the floor is capped, and with this row's "999" label it could
        // not have fired before the cap either, because the claim that was
        // under the floor was in the column that got dropped, so there was no
        // cell to complain about (round 3, 2026-09-20 — the per-cell form had
        // survived round 2's fix by accident).
        let mixedColumn = mixedPlan.columns.first { $0.kind == .context }
        if mixedColumn?.isDrawn != true {
            let shape = mixedColumn.map { column in
                "width \(Int(column.width))pt against a floor of \(Int(column.minimumWidth))pt"
            } ?? "no context column at all"
            print("  ✗ the context column was dropped: \(shape)")
            failures += 1
        }
        if drawn == 2, badgeRows == 1, tokenRows == 1 {
            print("  ✓ a token count and a badge share the context column and both are drawn "
                  + "at the smallest pet (\(Int(mixedPet))pt)")
        } else {
            print("  ✗ the mixed context column lost a row: \(drawn) of 2 cells drawn "
                  + "(\(badgeRows) badges, \(tokenRows) token counts) at a \(Int(mixedPet))pt pet")
            failures += 1
        }
        controller.resetActivities()

        return failures
    }

    /// Verifies the view will actually receive the click that starts a drag.
    ///
    /// Worth checking mechanically: the pet renders perfectly whether or not
    /// this works, and the failure mode is silent — a pet that animates but
    /// cannot be moved reads as a broken app with no visible cause.
    // MARK: - The manager window's lifecycle

    /// Counts how often SwiftUI hands a model change to its view.
    @MainActor
    private final class UpdateProbe: ObservableObject {
        @Published var tick = 0
        private(set) var deliveries = 0
        func noteDelivery() { deliveries += 1 }
    }

    private struct DeliveryCounter: NSViewRepresentable {
        let probe: UpdateProbe
        func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
        func updateNSView(_ view: NSView, context: Context) {
            MainActor.assumeIsolated { probe.noteDelivery() }
        }
    }

    private struct ProbeRoot: View {
        @ObservedObject var probe: UpdateProbe
        var body: some View {
            VStack {
                Text("tick \(probe.tick)")
                DeliveryCounter(probe: probe)
            }
        }
    }

    /// Does a window's SwiftUI tree come back to life when the window is opened
    /// again after being closed?
    ///
    /// The manager rebuilds its view tree on every reopen because a probe could
    /// not answer this — a probe process cannot get a window on screen the way
    /// an app bundle can, and SwiftUI skips updates for windows that are not
    /// visible, which is indistinguishable from the freeze being asked about.
    /// The app can answer it, so it does, every run: the answer decides whether
    /// that rebuild is load-bearing or merely cautious.
    private static func checkReopenedWindow() -> Int {
        print("")
        print("Manager window lifecycle")
        var failures = 0

        // The probe needs a window on screen, and a diagnostic run puts none
        // there. The answer it was written to get is recorded in
        // ARCHITECTURE §6.1 — SwiftUI does not bring an off-screen window's
        // tree back to life — so nothing is lost by skipping it here.
        guard !HeadlessMode.isActive else {
            print("  – skipped: a diagnostic run does not put windows on screen")
            return 0
        }

        let probe = UpdateProbe()
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 260, height: 160),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ProbeRoot(probe: probe))
        // The way the manager opens its window: on screen, key, app active.
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        let baseline = probe.deliveries
        probe.tick += 1
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        guard probe.deliveries > baseline else {
            // No window server, or SwiftUI is not updating windows here at all:
            // every answer below would be a false alarm.
            print("  – skipped: SwiftUI is not updating a visible window here "
                  + "(isVisible=\(window.isVisible), "
                  + "occlusion=\(window.occlusionState.contains(.visible)))")
            window.close()
            return 0
        }
        print("  ✓ an open window's tree receives the model's changes")

        window.close()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        let beforeStale = probe.deliveries
        probe.tick += 1
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let staleTreeRevives = probe.deliveries > beforeStale
        print("  – a window reopened with its old view tree receives them again: "
              + (staleTreeRevives ? "yes" : "no"))

        // The shape the manager uses.
        window.contentViewController = NSHostingController(rootView: ProbeRoot(probe: probe))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        let beforeFresh = probe.deliveries
        probe.tick += 1
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        if probe.deliveries > beforeFresh {
            print("  ✓ a rebuilt view tree receives them, which is what the manager does")
        } else {
            print("  ✗ not even a rebuilt view tree receives updates")
            failures += 1
        }

        window.close()
        return failures
    }

    /// The manager's sidebar toggle: in the window's toolbar, and in the same
    /// place whether the sidebar is open or closed.
    ///
    /// Both halves were wrong. The window had no toolbar at all — SwiftUI only
    /// installs one when the view declares toolbar content — so the split view
    /// fell back to drawing its own toggle inside the sidebar pane, and that
    /// fallback moved by the width of the column when the sidebar was hidden.
    private static func checkManagerSidebar() -> Int {
        print("")
        print("Manager sidebar")
        var failures = 0

        let model = AgentPetModel(
            root: BridgeSocketLocation.applicationSupportDirectory,
            shimPath: "/tmp/none"
        )
        // Opening the manager does not wait for a detection pass. The pass
        // spawns a `--version` process per agent — 0.57s for six of them when
        // this was written, seconds on a cold machine — and it used to run
        // before the window was ordered front (user report, 2026-09-18). The
        // call returns at once now, and the answers land behind it.
        let detectStarted = CFAbsoluteTimeGetCurrent()
        model.refreshAgents()
        let waited = CFAbsoluteTimeGetCurrent() - detectStarted
        var landed = false
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if !model.isRefreshingAgents, !model.agentStatuses.isEmpty {
                landed = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if waited < 0.1, landed {
            print("  ✓ a detection pass returns in \(Int(waited * 1000))ms and lands behind it "
                  + "(\(model.agentStatuses.count) agents) — the window does not wait for it")
        } else {
            print("  ✗ the detection pass blocked for \(Int(waited * 1000))ms "
                  + "(landed: \(landed), \(model.agentStatuses.count) agents)")
            failures += 1
        }

        // The size this check is about to prove is remembered is the user's
        // own on any machine that is not running isolated: read it, clear it
        // so the opening size below is the real default, and put it back once
        // the window has closed (closing re-writes it, so the restore has to
        // come last).
        let rememberedBefore = UserDefaults.standard.string(forKey: "manager.window.size")
        UserDefaults.standard.removeObject(forKey: "manager.window.size")
        defer {
            // After the window has closed, so its close does not overwrite
            // this: the answer belongs to the machine's user, not to the test.
            if let rememberedBefore {
                UserDefaults.standard.set(rememberedBefore, forKey: "manager.window.size")
            } else {
                UserDefaults.standard.removeObject(forKey: "manager.window.size")
            }
        }
        let manager = MainWindowController(model: model)
        manager.show()
        guard let window = NSApp.windows.first(where: { $0.title == "Agent Pet Runtime" }) else {
            print("  ✗ the manager did not open")
            return failures + 1
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        // What the window opens at, on made-up screens: no remembered size
        // means the default, the default gives way to a screen that cannot
        // hold it, a remembered size beats the default, and nothing gets under
        // the minimum.
        let roomy = NSSize(width: 4000, height: 3000)
        let laptop = NSSize(width: 1440, height: 875)
        let defaultSize = NSSize(width: 1620, height: 1224)
        let openingCases: [(stored: String?, available: NSSize?, want: NSSize)] = [
            (nil, roomy, defaultSize),
            (nil, nil, defaultSize),
            (nil, laptop, laptop),
            ("812.0,596.0", roomy, NSSize(width: 812, height: 596)),
            ("812.0,596.0", laptop, NSSize(width: 812, height: 596)),
            ("10,10", roomy, NSSize(width: 760, height: 520)),
            ("4000,3000", laptop, laptop),
            ("junk", roomy, defaultSize),
        ]
        var wrongSize: [String] = []
        for c in openingCases {
            let got = MainWindowController.openingContentSize(stored: c.stored,
                                                              available: c.available)
            if got != c.want {
                wrongSize.append("\(c.stored ?? "none") in \(Int(c.available?.width ?? -1))x"
                                 + "\(Int(c.available?.height ?? -1)) -> \(Int(got.width))x"
                                 + "\(Int(got.height)), want \(Int(c.want.width))x"
                                 + "\(Int(c.want.height))")
            }
        }
        if wrongSize.isEmpty {
            print("  ✓ the opening size: the 1620x1224 default, the user's own, the minimum, "
                  + "the screen")
        } else {
            print("  ✗ opening sizes wrong: \(wrongSize.joined(separator: "; "))")
            failures += 1
        }

        // And it really opened at what the rule says for this machine — never
        // under the minimum, so the Pets page stays a page.
        let opening = window.contentRect(forFrameRect: window.frame).size
        let expected = MainWindowController.openingContentSize(
            stored: nil, available: MainWindowController.availableContentSize(for: window))
        if opening == expected,
           window.contentMinSize.width >= 760, window.contentMinSize.height >= 520 {
            print("  ✓ the manager opens at \(Int(opening.width))x\(Int(opening.height)) "
                  + "and will not go below \(Int(window.contentMinSize.width))x"
                  + "\(Int(window.contentMinSize.height))")
        } else {
            print("  ✗ the manager window is \(Int(opening.width))x\(Int(opening.height)), "
                  + "the rule says \(Int(expected.width))x\(Int(expected.height)), "
                  + "minimum \(window.contentMinSize)")
            failures += 1
        }

        window.setContentSize(NSSize(width: 812, height: 596))
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
        let remembered = UserDefaults.standard.string(forKey: "manager.window.size")
        if remembered == "812.0,596.0" {
            print("  ✓ and a size it is dragged to is remembered (\(remembered ?? "-"))")
        } else {
            print("  ✗ the manager's size was not remembered: \(remembered ?? "nothing stored")")
            failures += 1
        }

        // Reopening must not cost the user that size. Every open swaps in a
        // fresh content view controller — that is what revives a window
        // SwiftUI had stopped updating (§6.5c) — and AppKit sizes a window to
        // its new content view controller the moment it is assigned. That
        // intermediate size was what got remembered, so a window the user had
        // sized came back at the minimum and stayed there for the next launch
        // too (user report, 2026-09-18).
        //
        // Closed first, because that is the reopen the swap is for: a window
        // that was only ever built — which is every window in a diagnostic
        // run, since none of them go on screen — may be brought forward
        // without one, and a check that measures that path would go green
        // without ever reaching the code it is here for.
        let treeBeforeClosing = window.contentViewController
        window.close()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        manager.show()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        // And it has to be a rebuild: the reason the swap exists is that a
        // window nobody rebuilds stops receiving SwiftUI's updates, so a green
        // check with the old tree still in place would be a false one.
        if window.contentViewController === treeBeforeClosing {
            print("  ✗ reopening a closed manager did not rebuild its view tree")
            failures += 1
        }
        let reopened = window.contentRect(forFrameRect: window.frame).size
        let stillStored = UserDefaults.standard.string(forKey: "manager.window.size")
        if abs(reopened.width - 812) < 1, abs(reopened.height - 596) < 1,
           stillStored == "812.0,596.0" {
            print("  ✓ reopening it keeps the size it was left at "
                  + "(\(Int(reopened.width))x\(Int(reopened.height)))")
        } else {
            print("  ✗ reopening the manager left it at \(Int(reopened.width))x"
                  + "\(Int(reopened.height)) and remembered \(stillStored ?? "nothing")")
            failures += 1
        }

        func toggleView() -> NSView? {
            guard let view = window.toolbar?.items.first?.view, view.window != nil else { return nil }
            return view
        }

        // The toggle has to be *in the toolbar* — SwiftUI only installs one
        // when the view declares toolbar content, and without it the split
        // view draws its own toggle inside the sidebar pane. That much is
        // visible to a window nobody can see; where it ends up is not.
        guard let toggle = toggleView() else {
            print("  ✗ the window has no toolbar item to toggle the sidebar with")
            window.close()
            return failures + 1
        }
        guard window.occlusionState.contains(.visible) else {
            print("  ✓ the toggle lives in the toolbar — position not checked: a diagnostic "
                  + "run puts no windows on screen, and SwiftUI does not lay out one it "
                  + "cannot be seen in")
            window.close()
            return failures
        }

        func toggleFrame() -> NSRect? {
            guard let view = toggleView() else { return nil }
            return view.convert(view.bounds, to: nil)
        }

        guard let open = toggleFrame() else {
            print("  ✗ the toolbar item has no frame")
            window.close()
            return failures + 1
        }
        print("  ✓ the toggle lives in the toolbar, at (\(Int(open.minX)),\(Int(open.minY)))")

        model.showsSidebar = false
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let closed = toggleFrame()
        if let closed, abs(closed.minX - open.minX) < 1, abs(closed.minY - open.minY) < 1 {
            print("  ✓ and it stays there when the sidebar is hidden")
        } else {
            print("  ✗ the toggle moved: \(closed.map { "(\(Int($0.minX)),\(Int($0.minY)))" } ?? "gone")"
                  + " against (\(Int(open.minX)),\(Int(open.minY)))")
            failures += 1
        }

        model.showsSidebar = true
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        window.close()
        return failures
    }

    /// ⌘, lands the manager on its Settings section.
    ///
    /// Driven through the menu, on purpose. The menu item *is* the feature, so
    /// a check that called the action itself would pass with the item missing,
    /// or installed on a shortcut the menu cannot match. It also drives the
    /// app's own manager rather than one built here: a manager the check built
    /// for itself would be a window the shortcut never touches — measured, by
    /// watching exactly that and seeing nothing happen.
    private static func checkSettingsShortcut() -> Int {
        print("")
        print("Settings shortcut")
        var failures = 0

        /// Every manager window in the process, whoever opened it.
        ///
        /// The check has to follow the window *the press* created, and it
        /// cannot do that by looking for one: the sidebar check before it opens
        /// a manager of its own and closes it, and a closed window with
        /// `isReleasedWhenClosed = false` stays in `NSApp.windows`; a
        /// diagnostic run puts none of them on screen, so `isVisible` cannot
        /// tell them apart either. Identity can.
        func managerWindows() -> [NSWindow] {
            NSApp.windows.filter { $0.title == "Agent Pet Runtime" }
        }

        let preexisting = Set(managerWindows().map(ObjectIdentifier.init))

        let item = NSApp.mainMenu?.items
            .compactMap { $0.submenu?.items.first { $0.keyEquivalent == "," } }
            .first
        guard let item else {
            print("  ✗ no ⌘, item anywhere in the main menu")
            return failures + 1
        }
        if item.keyEquivalentModifierMask == .command {
            print("  ✓ the main menu offers “\(item.title)” on ⌘,")
        } else {
            print("  ✗ “\(item.title)” needs more than ⌘: \(item.keyEquivalentModifierMask)")
            failures += 1
        }

        /// A key event for a window, in the shape AppKit's menu matcher reads:
        /// the modifier flags plus the characters *ignoring* modifiers are what
        /// a key equivalent is matched against, and a synthesized event has to
        /// carry them — an empty string matches nothing.
        func keyEvent(
            characters: String,
            keyCode: UInt16,
            modifiers: NSEvent.ModifierFlags,
            windowNumber: Int
        ) -> NSEvent? {
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )
        }

        /// What one press of ⌘, turned into: which route delivered it, and how
        /// long the action itself held the main thread.
        ///
        /// The duration is the thing the user feels: everything the action
        /// does runs before the window repaints, so a press that spends
        /// hundreds of milliseconds re-detecting agents and rebuilding the
        /// view tree *is* the second of delay, however fast the section
        /// change is in the model.
        struct Delivery {
            let route: String
            let milliseconds: Double

            var described: String { "delivered by \(route), action \(Int(milliseconds))ms" }
        }

        /// Presses ⌘, and reports what it cost. `window` is nil only for the
        /// first press, when the manager the press is about to open does not
        /// exist yet.
        ///
        /// `NSApplication.sendEvent` is the app's own path to a menu shortcut:
        /// the key event goes to the main menu, which matches it against the
        /// items' key equivalents and dispatches the one that fits. That route
        /// needs the app to be active — true once a manager window has opened,
        /// since opening one activates the app, but not guaranteed in every
        /// environment — so when it delivers nothing the menu is asked
        /// directly: the same match, one step in from where AppKit calls it,
        /// and the only route that works with an inactive app. Which of the
        /// two ran is printed rather than assumed.
        func press(in window: NSWindow?, until changed: () -> Bool) -> Delivery {
            // 43 is the comma key on this keyboard.
            guard let event = keyEvent(characters: ",", keyCode: 43, modifiers: .command,
                                       windowNumber: window?.windowNumber ?? 0) else {
                return Delivery(route: "no event", milliseconds: 0)
            }

            var started = ProcessInfo.processInfo.systemUptime
            NSApp.sendEvent(event)
            var spent = (ProcessInfo.processInfo.systemUptime - started) * 1000
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            if changed() { return Delivery(route: "NSApplication.sendEvent", milliseconds: spent) }

            started = ProcessInfo.processInfo.systemUptime
            let handled = NSApp.mainMenu?.performKeyEquivalent(with: event) == true
            spent = (ProcessInfo.processInfo.systemUptime - started) * 1000
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            return Delivery(route: handled && changed() ? "the main menu" : "nothing", milliseconds: spent)
        }

        // Closed: the shortcut has to open one, on Settings.
        let openedBy = press(in: nil) { managerWindows().count > preexisting.count }
        guard let opened = managerWindows().first(where: { !preexisting.contains(ObjectIdentifier($0)) }) else {
            print("  ✗ ⌘, did not open a manager window (\(openedBy.described))")
            return failures + 1
        }

        /// The model behind the window the press opened — what a user sees
        /// change is its view tree, and the section lives in the model because
        /// this window rebuilds that tree when it is reopened.
        func managerModel() -> AgentPetModel? {
            (opened.contentViewController as? NSHostingController<MainWindowView>)?.rootView.model
        }

        if managerModel()?.section == .settings {
            print("  ✓ from a closed manager, ⌘, opens it on Settings"
                  + (opened.subtitle == "Settings" ? " — title bar included" : "")
                  + " (\(openedBy.described))")
        } else {
            print("  ✗ the manager opened on \(managerModel()?.section.rawValue ?? "no model")")
            failures += 1
        }

        // Open, and elsewhere in it: the shortcut has to move that window —
        // and only that. This is the case the shortcut exists for, since the
        // menu bar is only there while the manager window is; it is also the
        // one that used to take about a second, waiting on work a section
        // switch does not need.
        //
        // The title bar is what turns "the model changed" into "the window
        // changed": it and the sidebar read the same section, so a tree that
        // repainted one repainted the other. Where the environment cannot
        // repaint a window at all — a diagnostic run puts none on screen —
        // that half is reported as unchecked rather than assumed.
        managerModel()?.section = .activity
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let repaints = opened.subtitle == "Activity"
        if !repaints {
            print("  – this window is not repainting here; the move is checked on the model alone")
        }

        // The view tree the window already had, so "it switched the section"
        // can be told from "it built the window again": a new controller means
        // the whole tree was thrown away and rebuilt, which is worth a
        // measured 200ms and is only ever needed for a window that had been
        // closed.
        let treeBefore = opened.contentViewController
        let movedBy = press(in: opened) { managerModel()?.section == .settings }
        let treeAfter = opened.contentViewController

        if managerModel()?.section != .settings {
            print("  ✗ ⌘, left the manager on \(managerModel()?.section.rawValue ?? "no model")"
                  + " (title bar: \(opened.subtitle), \(movedBy.described))")
            failures += 1
        } else if treeAfter !== treeBefore {
            print("  ✗ switching a section rebuilt the window's view tree (\(movedBy.described))")
            failures += 1
        } else if !(opened.subtitle == "Settings" || !repaints) {
            print("  ✗ the model moved but the window did not: title bar says \(opened.subtitle)")
            failures += 1
        } else if movedBy.milliseconds > 250 {
            // Detection is a measured 445ms of `--version` process spawning
            // and the rebuild about 200ms; a section switch needs neither, so
            // anything in this range means one of them crept back in.
            print("  ✗ the switch held the main thread for \(Int(movedBy.milliseconds))ms — "
                  + "that is the delay this shortcut used to have. \(movedBy.described)")
            failures += 1
        } else {
            print("  ✓ from Activity, ⌘, moves the same window to Settings,"
                  + " without touching the view tree (\(movedBy.described))")
        }

        // A focused settings field must not eat the shortcut — the likeliest
        // moment to press ⌘, is while typing in one of Settings' number
        // fields, with the cursor already in it.
        //
        // Proven with the window's other menu shortcut, ⌃⌘S (Toggle Sidebar,
        // View menu), because the sidebar is observable here while the section
        // is not: the manager is already on Settings, so ⌘, would have nothing
        // left to change. Menu key equivalents are matched ahead of text
        // input: the field editor is offered the event first and declines the
        // keys it does not own, and neither "," nor ⌃⌘S is one of them.
        func firstEditableField() -> NSTextField? {
            var found: NSTextField?
            func walk(_ view: NSView) {
                if found != nil { return }
                if let field = view as? NSTextField, field.isEditable { found = field; return }
                for sub in view.subviews { walk(sub) }
            }
            if let content = opened.contentView { walk(content) }
            return found
        }

        if let field = firstEditableField(),
           let event = keyEvent(characters: "s", keyCode: 1, modifiers: [.control, .command],
                                windowNumber: opened.windowNumber) {
            opened.makeFirstResponder(field)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            // A focused field means its field editor is the first responder;
            // without that the check would prove nothing about focus.
            let focused = opened.firstResponder is NSTextView
            let before = managerModel()?.showsSidebar
            NSApp.sendEvent(event)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            var after = managerModel()?.showsSidebar
            if after == before {
                opened.sendEvent(event)
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                after = managerModel()?.showsSidebar
            }
            if focused, after != before {
                print("  ✓ with a settings field focused, a menu shortcut still fires (⌃⌘S flipped the sidebar)")
            } else {
                print("  ✗ a focused field ate the shortcut (field editor focused: \(focused))")
                failures += 1
            }
            managerModel()?.showsSidebar = true
        } else {
            print("  – no editable field in the window to test focus against")
        }

        // Said rather than left implied: this run cannot test a manager window
        // that is minimized in the Dock — it refuses to minimize one at all
        // (measured: `miniaturize(nil)` leaves `isMiniaturized` false).
        print("  – not checked: ⌘, with the manager minimized")

        opened.close()
        return failures
    }

    private static func checkDraggable(view: PetView) -> Int {
        print("")
        print("Drag readiness")
        var failures = 0

        // An accessory app is essentially never active, so without this the
        // first click would be spent activating and never reach the view.
        if view.acceptsFirstMouse(for: nil) {
            print("  ✓ acceptsFirstMouse — a click from another app reaches the pet")
        } else {
            print("  ✗ acceptsFirstMouse is false — the first click would be swallowed")
            failures += 1
        }

        // The centre of the view must be grabbable.
        let centre = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        if view.hitTest(centre) === view {
            print("  ✓ hitTest returns the pet at its centre")
        } else {
            print("  ✗ hitTest does not return the pet at its centre — it cannot be grabbed")
            failures += 1
        }

        // …and just outside it must pass clicks through, or the pet would
        // steal clicks meant for whatever is behind it.
        let outside = NSPoint(x: view.bounds.maxX + 20, y: view.bounds.midY)
        if view.hitTest(outside) == nil {
            print("  ✓ clicks outside the pet pass through to what is behind it")
        } else {
            print("  ✗ the pet captures clicks outside its own bounds")
            failures += 1
        }

        // Grab geometry must survive a round trip.
        let origin = CGPoint(x: 800, y: 300)
        let grab = WindowDrag.grabOffset(mouse: CGPoint(x: 850, y: 380), windowOrigin: origin)
        let returned = WindowDrag.origin(mouse: CGPoint(x: 850, y: 380), grabOffset: grab)
        if returned == origin {
            print("  ✓ drag geometry returns the window to its start")
        } else {
            print("  ✗ drag geometry drifts: \(origin) -> \(returned)")
            failures += 1
        }

        return failures
    }
}
