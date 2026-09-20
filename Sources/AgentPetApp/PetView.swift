import AgentPetCore
import AppKit
import CoreText

/// Draws the current sprite frame, the session panel above it, and handles
/// dragging.
///
/// Deliberately dumb: it knows how to put one `CGImage` on screen, how to draw
/// a row of short labels above it, and how to be dragged. All decisions about
/// *which* frame and *which* rows belong on screen live in `AgentPetCore`, so
/// the preview in a manager window and the desktop pet cannot drift apart.
final class PetView: NSView {

    private var image: CGImage?
    private var panel: MessagePanel = .empty
    private var panelConfig = MessagePanelConfig()

    /// How wide the pet is drawn, in points. Told by the owner rather than
    /// derived from the bounds: with a wide panel up, the view is wider than
    /// the pet, and the message line is sized from the pet.
    var petWidth: CGFloat = CGFloat(AppConfig.PetConfig.defaultWidth)

    /// How tall the panel strip must be for a panel.
    static func panelHeight(
        for panel: MessagePanel,
        config: MessagePanelConfig,
        petWidth: CGFloat
    ) -> CGFloat {
        MessagePanelLayout.plan(for: panel, config: config, petWidth: petWidth).height
    }

    /// The part of the view the sprite occupies.
    ///
    /// The panel takes the strip above the pet, so the pet itself never moves
    /// — the window grows upward instead. Sideways, the panel is anchored to
    /// the pet: with `.left` its left edge is the pet's, so the pet sits at
    /// the window's left and the panel extends to its right; `.center` keeps
    /// the pet in the middle of the window, which is what it has always done;
    /// `.right` puts the pet at the window's right edge.
    var spriteRect: CGRect {
        let inset = Self.panelHeight(for: panel, config: panelConfig, petWidth: petWidth)
        let originX = panelConfig.alignment.spriteOriginX(
            inWindowWidth: bounds.width, petWidth: petWidth
        )
        return CGRect(
            x: bounds.minX + originX, y: bounds.minY,
            width: min(bounds.width, petWidth), height: max(0, bounds.height - inset)
        )
    }

    /// Set by the controller so a drag can move the window rather than the view.
    var onDrag: ((NSPoint) -> Void)?
    /// Fires when the pet is picked up, so it can switch to locomotion.
    var onDragBegan: (() -> Void)?
    /// A click that was not a drag — the pet's cue to greet.
    var onClick: (() -> Void)?
    /// Double-clicking the pet opens the manager.
    var onDoubleClick: (() -> Void)?
    /// Right-clicking the pet raises the same menu as the status item.
    ///
    /// The pet is the thing the user is looking at, so it is where they will
    /// reach for the controls. Hunting for a menu bar icon is a needless step.
    var onRightClick: ((NSEvent) -> Void)?
    /// Called once a drag finishes, so the position can be persisted then
    /// rather than only at quit — a crash would otherwise lose it.
    var onDragEnded: (() -> Void)?

    /// The pointer arrived on the pet, or left it.
    ///
    /// Codex's pet plays its `jumping` row for this and holds the landing pose
    /// until the pointer goes, so the two events are not the same as a click.
    var onHoverBegan: (() -> Void)?
    var onHoverEnded: (() -> Void)?

    /// Tracks the sprite only. Tracking the whole view would make the pet jump
    /// when the pointer crossed the message panel above it.
    private var hoverTracking: NSTrackingArea?

    /// Distance from the window's origin to the mouse when the drag began,
    /// in screen coordinates.
    private var grabOffset: NSPoint?
    private var didMove = false

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    /// **Required, and the reason the pet could not be dragged.**
    ///
    /// The app runs as an accessory, so it is essentially never the active
    /// application. AppKit's default is to deliver the first click in an
    /// inactive window to the window itself for activation and *not* to the
    /// view — which is exactly right for most windows and completely wrong for
    /// a desktop pet, which the user clicks precisely because they are working
    /// somewhere else.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The window is click-through except over the pet itself, so it never
    /// steals clicks meant for whatever is behind it. The message is not
    /// grabbable: dragging the pet is how it is moved, and a panel that moved
    /// when someone tried to click its text would be a surprise.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Before the first frame arrives there is nothing to grab, so the
        // window passes clicks straight through.
        guard let image else { return nil }
        let drawn = Self.fittedRect(
            imageSize: CGSize(width: image.width, height: image.height),
            in: spriteRect
        )
        // A small margin so the pet is not fiddly to grab.
        return drawn.insetBy(dx: -4, dy: -4).contains(point) ? self : nil
    }

    func show(_ image: CGImage?) {
        guard self.image !== image else { return }
        self.image = image
        needsDisplay = true
    }

    /// Sets the panel drawn above the pet. The window size follows from this,
    /// so the owner is told when it changes.
    func show(_ panel: MessagePanel, config: MessagePanelConfig) {
        guard panel != self.panel || config != self.panelConfig else { return }
        self.panel = panel
        self.panelConfig = config
        needsDisplay = true
        // The sprite moved: the pointer's idea of where the pet is has to move
        // with it, or a panel appearing under the cursor would leave the pet
        // thinking it is still being hovered.
        updateTrackingAreas()
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(
            rect: spriteRect,
            // `.activeAlways`: the app is an accessory and its pet is almost
            // never in a key window, which is exactly the case `.activeInKeyWindow`
            // would drop.
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverBegan?()
    }

    override func mouseExited(with event: NSEvent) {
        onHoverEnded?()
    }

    /// What is currently set to be drawn. Read by the render self-test.
    var currentImage: CGImage? { image }
    var currentPanel: MessagePanel { panel }
    var currentPanelConfig: MessagePanelConfig { panelConfig }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }

        let sprite = spriteRect
        let target = Self.fittedRect(
            imageSize: CGSize(width: image.width, height: image.height),
            in: sprite
        )

        if Self.isLoggingFrames {
            FileHandle.standardError.write(Data(
                "[pet] draw bounds=\(bounds) target=\(target) image=\(image.width)x\(image.height)\n".utf8
            ))
        }

        context.saveGState()
        // The decoded buffer is already premultiplied and top-left origin;
        // telling CoreGraphics to smooth it would soften the pixel art edges.
        context.interpolationQuality = .none
        context.draw(image, in: target)
        context.restoreGState()

        let plan = MessagePanelLayout.plan(for: panel, config: panelConfig, petWidth: petWidth)
        if !plan.rows.isEmpty {
            drawPanel(plan, spriteRect: sprite)
        }
    }

    // MARK: - Panel

    /// Draws the session rows in the strip above the pet.
    private func drawPanel(_ plan: MessagePanelLayout.Plan, spriteRect: CGRect) {
        let metrics = plan.metrics
        let height = plan.height
        let area = CGRect(
            x: bounds.minX, y: bounds.maxY - height, width: bounds.width, height: height
        )
        let bubble = area.insetBy(dx: 2, dy: 0)
        let bodyRect = CGRect(
            x: bubble.minX, y: bubble.minY,
            width: bubble.width, height: bubble.height - metrics.tailHeight
        )

        // A tail centred on the pet, pointing down at it.
        let tailWidth = 10 * metrics.scale
        let tail = CGMutablePath()
        tail.move(to: CGPoint(
            x: spriteRect.midX - tailWidth / 2,
            y: bubble.minY + metrics.tailHeight
        ))
        tail.addLine(to: CGPoint(x: spriteRect.midX, y: bubble.minY))
        tail.addLine(to: CGPoint(
            x: spriteRect.midX + tailWidth / 2,
            y: bubble.minY + metrics.tailHeight
        ))

        let shape = CGMutablePath()
        shape.addRoundedRect(in: bodyRect, cornerWidth: 6 * metrics.scale,
                             cornerHeight: 6 * metrics.scale)
        shape.addPath(tail)

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.addPath(shape)
        context.setFillColor(NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor)
        context.fillPath()
        context.addPath(shape)
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(1)
        context.strokePath()
        context.restoreGState()

        // Rows run downward from the top of the bubble.
        var rowTop = bodyRect.maxY - metrics.padding
        for row in plan.rows {
            let rowRect = CGRect(
                x: bodyRect.minX,
                y: rowTop - metrics.rowHeight,
                width: bodyRect.width,
                height: metrics.rowHeight
            )
            drawRow(row, in: rowRect, columns: plan.columns, metrics: metrics)
            rowTop = rowRect.minY - metrics.rowSpacing
        }
    }

    private func drawRow(
        _ row: MessagePanelLayout.Row,
        in rowRect: CGRect,
        columns: [MessagePanelLayout.Column],
        metrics: MessagePanelLayout.Metrics
    ) {
        for (item, frame) in MessagePanelLayout.frames(
            for: row, columns: columns, metrics: metrics
        ) {
            let rect = CGRect(
                x: rowRect.minX + frame.minX,
                y: rowRect.minY,
                width: frame.width,
                height: metrics.rowHeight
            )
            switch item.kind {
            case .context:
                drawContext(item, in: rect, metrics: metrics)
            case .message:
                drawMessage(item, in: rect, isFocused: row.isFocused, metrics: metrics)
            case .agent:
                if !drawSymbol(item, in: rect, metrics: metrics) {
                    Self.text(item.primary, font: metrics.agentFont)
                        .draw(in: rect.insetBy(dx: 0, dy: 2.5 * metrics.scale))
                }
            case .session:
                Self.text(item.primary, font: metrics.sessionFont,
                          color: .secondaryLabelColor)
                    .draw(in: rect.insetBy(dx: 0, dy: 3 * metrics.scale))
            default:
                Self.text(item.primary, font: metrics.itemFont,
                          color: .secondaryLabelColor)
                    .draw(in: rect.insetBy(dx: 0, dy: 3 * metrics.scale))
            }
        }
    }

    /// Draws an item's symbol, if it has one, centred in its column.
    ///
    /// Tinted by hand — the glyph is drawn, then filled through with the label
    /// colour using `.sourceAtop`, which paints only where the symbol is. SF
    /// Symbols arrive as template images, and a template drawn directly takes
    /// the context's fill colour only inside a control.
    private func drawSymbol(
        _ item: MessagePanelLayout.Item,
        in rect: CGRect,
        metrics: MessagePanelLayout.Metrics
    ) -> Bool {
        guard let name = item.symbolName,
              let symbol = NSImage(systemSymbolName: name, accessibilityDescription: item.primary)?
                  .withSymbolConfiguration(NSImage.SymbolConfiguration(
                      pointSize: 11 * metrics.scale, weight: .semibold))
        else { return false }

        let size = symbol.size
        let target = CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        let tinted = NSImage(size: size, flipped: false) { frame in
            symbol.draw(in: frame)
            NSColor.labelColor.set()
            frame.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: target)
        return true
    }

    /// The usage badge: a ring with the reading inside it.
    ///
    /// A ring rather than the bar this used to be. The bar was 46pt of a row
    /// that has to hold nine items beside a pet, and on a narrow panel it was
    /// the part of the row that pushed the status wording out (user request,
    /// 2026-09-20). The number sits inside the ring rather than beside it
    /// because inside is the only place it is ever drawn: beside it, the item
    /// asks for the ring and the number, the squeeze gives every non-flexible
    /// column its floor, and the number was never on screen at all with more
    /// than a handful of items enabled. It costs the size — three fifths of
    /// the panel's own text, measured in `baseContextRingFontRatio` — and buys
    /// a reading that is always there.
    ///
    /// The filled arc is fluorescent green on purpose: it is the one number
    /// here that changes on its own and is worth noticing from across the room.
    ///
    /// Both marks come from `MessagePanelLayout.usageLayout`, and both stay
    /// inside the column because the item floors at the ring's own width —
    /// the bar this replaced was drawn at its own width whatever the column had
    /// been squeezed to, and ran under the wording beside it.
    private func drawContext(
        _ item: MessagePanelLayout.Item,
        in rect: CGRect,
        metrics: MessagePanelLayout.Metrics
    ) {
        let layout = MessagePanelLayout.usageLayout(item, in: rect, metrics: metrics)

        if let ring = layout.ring, let context = item.context,
           let fraction = MessagePanelLayout.usageFraction(context) {
            let centre = CGPoint(x: ring.midX, y: ring.midY)
            let lineWidth = metrics.contextRingLineWidth
            let radius = (ring.width - lineWidth) / 2

            let track = NSBezierPath()
            track.appendArc(withCenter: centre, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = lineWidth
            NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
            track.stroke()

            if fraction > 0 {
                // Twelve o'clock, clockwise. This view is not flipped, so 90°
                // is straight up and the arc walks back down from there — the
                // direction it fills in is the direction a gauge fills in.
                let arc = NSBezierPath()
                arc.appendArc(withCenter: centre, radius: radius,
                              startAngle: 90, endAngle: 90 - 360 * fraction,
                              clockwise: true)
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                MessagePanelLayout.usageColor.setStroke()
                arc.stroke()
            }

            // Drawn through Core Text rather than `NSAttributedString.draw`,
            // because the position that matters is the *ink's* and not the line
            // box's: `draw(in:)` puts a line at the top of the rect it is given,
            // which would hang a digit — no descender, so its ink sits at the
            // top of its line box — against the stroke above it.
            if let digits = layout.digits, let context = NSGraphicsContext.current?.cgContext {
                let string = NSAttributedString(
                    string: MessagePanelLayout.percentDigits(fraction),
                    attributes: [
                        .font: metrics.contextRingFont,
                        .foregroundColor: NSColor.labelColor.cgColor,
                    ]
                )
                let line = CTLineCreateWithAttributedString(string)
                context.saveGState()
                context.textPosition = MessagePanelLayout.origin(
                    centring: CTLineGetBoundsWithOptions(line, .useGlyphPathBounds), in: digits
                )
                CTLineDraw(line, context)
                context.restoreGState()
            }
        }

        if let text = layout.text {
            Self.text(item.primary, font: metrics.itemFont,
                      color: .secondaryLabelColor)
                .draw(in: text.insetBy(dx: 0, dy: 3 * metrics.scale))
        }
    }

    /// The wording the pet has always used, now one row among several.
    private func drawMessage(
        _ item: MessagePanelLayout.Item,
        in rect: CGRect,
        isFocused: Bool,
        metrics: MessagePanelLayout.Metrics
    ) {
        let font = metrics.messageFont
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let string = NSMutableAttributedString(
            string: item.primary,
            attributes: [
                .font: font,
                .foregroundColor: isFocused ? NSColor.labelColor : NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
        )
        if let body = item.secondary {
            string.append(NSAttributedString(
                string: " — \(body)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: font.pointSize),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .paragraphStyle: paragraph,
                ]
            ))
        }
        string.draw(in: rect.insetBy(dx: 0, dy: 2.5 * metrics.scale))
    }

    private static func text(
        _ string: String,
        font: NSFont,
        color: NSColor = .labelColor
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: string, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ])
    }

    /// Set to have the view report what it draws. Off by default: this fires
    /// sixty times a second.
    static var isLoggingFrames = false

    /// Aspect-fit the cell inside the view without distorting it. Cells are
    /// 192x208, so a view of a different shape must letterbox rather than
    /// stretch the pet.
    static func fittedRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    // MARK: - Dragging

    // The arithmetic lives in `WindowDrag`, where it is pure and tested. In
    // particular it uses screen coordinates: the window's own coordinate
    // system moves with the window, so differencing it during a drag feeds
    // each move back into the next calculation.

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        guard let window else { return }
        grabOffset = WindowDrag.grabOffset(
            mouse: NSEvent.mouseLocation,
            windowOrigin: window.frame.origin
        )
        didMove = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grabOffset else { return }
        if !didMove {
            didMove = true
            // Announced on the first movement, not on mouse-down, so a click
            // that never moves is a greeting rather than a zero-length drag.
            onDragBegan?()
        }
        onDrag?(WindowDrag.origin(mouse: NSEvent.mouseLocation, grabOffset: grabOffset))
    }

    override func mouseUp(with event: NSEvent) {
        grabOffset = nil
        if didMove {
            onDragEnded?()
        } else {
            onClick?()
        }
        didMove = false
    }
}
