import AgentPetCore
import AppKit

/// Turns a `MessagePanel` into rectangles.
///
/// Kept apart from drawing and from the window, because three callers need the
/// same answers: the view draws them, the window sizes itself from them, and
/// the self-test measures them. One layout, computed the same way each time.
///
/// Main-actor because it holds fonts and a colour, and AppKit types are not
/// `Sendable`; every caller draws on the main thread anyway.
@MainActor
enum MessagePanelLayout {

    /// The numbers the panel is measured with at the baseline. What a panel
    /// actually draws with is `Metrics`, which multiplies every one of them by
    /// the scale its text asks for.
    nonisolated static let baseRowHeight: CGFloat = 18
    nonisolated static let baseRowSpacing: CGFloat = 2
    nonisolated static let basePadding: CGFloat = 9
    nonisolated static let baseSpacing: CGFloat = 8
    nonisolated static let baseTailHeight: CGFloat = 4
    /// Narrower than this and an item says nothing useful.
    nonisolated static let baseMinimumItemWidth: CGFloat = 34
    nonisolated static let baseContextBarSize = CGSize(width: 46, height: 7)
    /// The width an icon item is drawn at.
    nonisolated static let baseIconItemWidth: CGFloat = 13
    /// The width a message's own text may ask for before it is treated as
    /// flexible, at the baseline size.
    nonisolated static let baseMessageWidthCap: CGFloat = 300
    /// How much detail the panel makes room for when it is fitting itself to
    /// its content: about two dozen characters at the panel's own text size.
    ///
    /// The fit is measured on the message's *label*, so without this the panel
    /// would come to rest at the width of "Needs input…" and the line under
    /// it — which tool an approval is waiting on, what failed, the assistant's
    /// last words — would never be drawn at all. A fixed amount, not the
    /// detail's own length, so the width does not change with every message.
    nonisolated static let baseMessageDetailAllowance: CGFloat = 120
    /// The agent's own label, the one thing in the row deliberately larger
    /// than the rest of it.
    nonisolated static let baseAgentFontSize: CGFloat = 11.5

    /// Fluorescent green, the one colour in the panel that is not a system
    /// colour: how full a context window is has to be readable at a glance
    /// from across the room, on any desktop picture.
    static let usageColor = NSColor(srgbRed: 57 / 255, green: 255 / 255, blue: 20 / 255, alpha: 1)

    /// Every number the panel draws with, at the scale its text asks for.
    ///
    /// **One scale drives all of it.** The message, the other labels, the
    /// agent's glyph, the usage bar, the row height, the padding, the tail:
    /// at the default setting on the default pet every one of them is the
    /// number it has always been, and anything that doubles the text — a
    /// bigger setting, a bigger pet — doubles the panel with it.
    ///
    /// It used to be the message's own font that followed, on the grounds that
    /// the message is the line the user reads. Beside itself it read as a bug
    /// instead: at 20pt the status wording was drawn next to a 10.5pt task
    /// name, a 13pt glyph and a 7pt bar, which is two panels in one row — and
    /// raising the *pet* made the rest of the row relatively smaller still,
    /// since the panel's width follows the pet while the text did not (user
    /// report, 2026-09-18).
    ///
    /// The panel's *width* is deliberately not here: it stays a percentage of
    /// the pet, so the text size never moves the window.
    struct Metrics: Equatable {
        /// How much larger than the baseline this panel is drawn: 1 at the
        /// default text size on the default pet.
        let scale: CGFloat
        let messageFont: NSFont
        let agentFont: NSFont
        let itemFont: NSFont
        let sessionFont: NSFont
        let rowHeight: CGFloat
        let rowSpacing: CGFloat
        let padding: CGFloat
        let spacing: CGFloat
        let tailHeight: CGFloat
        let minimumItemWidth: CGFloat
        let iconItemWidth: CGFloat
        let messageWidthCap: CGFloat
        let messageDetailAllowance: CGFloat
        let contextBarSize: CGSize
    }

    /// The font size the panel draws at.
    ///
    /// The manual setting — unless the panel scales itself with the pet, in
    /// which case it is the default size, whose ratio to the default pet is
    /// what makes it follow the pet: 10.5pt at 112pt, 21pt at 224pt.
    static func effectiveFontSize(for config: MessagePanelConfig) -> Double {
        config.autoScale
            ? MessagePanelConfig.defaultFontSize
            : MessagePanelConfig.clampFontSize(config.messageFontSize)
    }

    static func metrics(for config: MessagePanelConfig, petWidth: CGFloat) -> Metrics {
        let base = CGFloat(MessagePanelConfig.defaultFontSize)
        let points = CGFloat(effectiveFontSize(for: config))
            * (petWidth / CGFloat(AppConfig.PetConfig.defaultWidth))
        let scale = max(0.1, points / base)
        return Metrics(
            scale: scale,
            messageFont: NSFont.systemFont(ofSize: points, weight: .semibold),
            agentFont: NSFont.systemFont(ofSize: baseAgentFontSize * scale, weight: .semibold),
            itemFont: NSFont.systemFont(ofSize: base * scale),
            sessionFont: NSFont.monospacedSystemFont(ofSize: base * scale, weight: .regular),
            rowHeight: (baseRowHeight * scale).rounded(),
            rowSpacing: baseRowSpacing * scale,
            padding: basePadding * scale,
            spacing: baseSpacing * scale,
            tailHeight: baseTailHeight * scale,
            minimumItemWidth: baseMinimumItemWidth * scale,
            iconItemWidth: baseIconItemWidth * scale,
            messageWidthCap: baseMessageWidthCap * scale,
            messageDetailAllowance: baseMessageDetailAllowance * scale,
            contextBarSize: CGSize(width: baseContextBarSize.width * scale,
                                   height: baseContextBarSize.height * scale)
        )
    }

    /// The widest the panel may be drawn: the width setting, which is a
    /// percentage of the pet's own width — "200%" means twice the pet at
    /// whatever size the pet is drawn — times the text size's own factor
    /// against the default.
    ///
    /// The panel is one drawing at one scale, and the text size setting is its
    /// zoom: a setting that enlarges the row by 1.9 also widens the panel by
    /// 1.9, or the row would be asked to hold the same content in a panel that
    /// did not grow with it (user decision, 2026-09-18). Deliberately the
    /// *setting's* factor and not `Metrics.scale`, which carries the pet's
    /// factor as well: the pet already widens the panel, and counting it twice
    /// would make the panel four times as wide at a pet twice the size.
    ///
    /// When the panel scales itself with the pet, this is the *default*
    /// percentage of it: the manual width is one of the two settings that
    /// deliberately do not apply there.
    static func maximumPanelWidth(for config: MessagePanelConfig, petWidth: CGFloat) -> CGFloat {
        let percent = config.autoScale
            ? MessagePanelConfig.defaultWidthPercent
            : MessagePanelConfig.clampWidth(config.widthPercent)
        let zoom = CGFloat(effectiveFontSize(for: config))
            / CGFloat(MessagePanelConfig.defaultFontSize)
        return (petWidth * CGFloat(percent) / 100 * zoom).rounded()
    }

    struct Item {
        let kind: MessagePanelConfig.Kind
        let primary: String
        let secondary: String?
        let context: SessionContext?
        /// What the item would draw at if the row had room to spare.
        let width: CGFloat
        /// What the *panel* is asked to be sized for, when it fits itself to
        /// its content.
        ///
        /// The same as `width` for everything but the message, whose detail
        /// can run to 200 characters: sizing the panel to that would pin it to
        /// the user's maximum forever, and take the detail out of the fit —
        /// the label plus a fixed allowance for the detail — so the panel
        /// follows the short columns and the detail fills what is left.
        let fitWidth: CGFloat
        let isFlexible: Bool
        /// An SF Symbol to draw instead of the text, for items that are a mark
        /// rather than a word.
        var symbolName: String?
        /// The narrowest this item may be drawn — and so the width below which
        /// it is left out entirely.
        ///
        /// Half the general minimum by default: narrower than that and a label
        /// says nothing. A glyph is the exception, and says so here, because a
        /// thirteen-point icon is not a squeezed word.
        var minimumWidth: CGFloat = MessagePanelLayout.baseMinimumItemWidth / 2
        /// What the squeeze takes this item down to before it starts on
        /// anything else.
        ///
        /// The general floor for every item but the message, which is the one
        /// item whose content is a sentence rather than a label: at twice the
        /// text size a row that stops at the floor hands back "Needs inpu…",
        /// *less* of the status wording than the same row drew at the default
        /// size. So the message claims the width of its own label, plus the
        /// ellipsis that marks the detail as cut, and the room comes out of
        /// the items that only name things.
        ///
        /// A claim the row cannot pay is not a claim: `frames` caps this at
        /// what is left once every other item keeps its `minimumWidth`.
        var preferredWidth: CGFloat = MessagePanelLayout.baseMinimumItemWidth

        init(
            kind: MessagePanelConfig.Kind,
            primary: String,
            secondary: String?,
            context: SessionContext?,
            width: CGFloat,
            fitWidth: CGFloat? = nil,
            isFlexible: Bool,
            symbolName: String? = nil,
            minimumWidth: CGFloat = MessagePanelLayout.baseMinimumItemWidth / 2,
            preferredWidth: CGFloat = MessagePanelLayout.baseMinimumItemWidth
        ) {
            self.kind = kind
            self.primary = primary
            self.secondary = secondary
            self.context = context
            self.width = width
            self.fitWidth = fitWidth ?? width
            self.isFlexible = isFlexible
            self.symbolName = symbolName
            self.minimumWidth = minimumWidth
            self.preferredWidth = preferredWidth
        }
    }

    /// One column of the panel: an item kind's slot, shared by every row.
    ///
    /// Rows are laid out on shared columns rather than each to its own
    /// content. Laid out per row, a session id one character longer than
    /// another's shifted everything after it along that row, and the panel
    /// read as several panels stacked rather than as one dashboard (user
    /// report, 2026-09-18). A row with nothing for a column leaves the cell
    /// blank; the columns after it do not move up.
    struct Column {
        let kind: MessagePanelConfig.Kind
        let isFlexible: Bool
        /// What the panel is asked to be sized for: the widest cell in the
        /// column, in `Item.fitWidth` terms.
        let fitWidth: CGFloat
        /// What the column would draw at if the panel had room to spare.
        let wantedWidth: CGFloat
        /// Below this the column says nothing, and is left out of every row.
        let minimumWidth: CGFloat
        /// The width the squeeze keeps for this column before anything else
        /// gives way — the message's own wording, the general floor for the
        /// rest.
        let preferredWidth: CGFloat
        /// The width it is drawn at, after the squeeze and any slack.
        var width: CGFloat

        /// Whether the panel can afford the column at all.
        var isDrawn: Bool { width + 0.01 >= minimumWidth }
    }

    struct Row {
        let id: String
        let isFocused: Bool
        let items: [Item]
    }

    struct Plan {
        let rows: [Row]
        /// Shared by every row: this is the panel's column layout.
        let columns: [Column]
        let alignment: MessagePanelConfig.Alignment
        let metrics: Metrics
        /// The panel's own width — the window's, when there are rows. Either
        /// what the content needs, or the maximum the settings allow.
        let width: CGFloat

        var height: CGFloat {
            guard !rows.isEmpty else { return 0 }
            return CGFloat(rows.count) * metrics.rowHeight
                + CGFloat(rows.count - 1) * metrics.rowSpacing
                + metrics.padding * 2 + metrics.tailHeight
        }
    }

    // MARK: - Items

    /// The items one row would draw, in configured order.
    ///
    /// Content that does not exist is left out rather than drawn as a blank:
    /// a session with no status line has no context figure, and an empty bar
    /// would read as a full one at a glance.
    static func items(
        for row: MessagePanel.Row,
        config: MessagePanelConfig,
        petWidth: CGFloat
    ) -> [Item] {
        let metrics = Self.metrics(for: config, petWidth: petWidth)
        // A name's cap scales with the row: it is there to stop one long name
        // eating the panel, and at twice the scale it takes twice the width to
        // do that.
        func capped(_ text: String, _ points: CGFloat) -> CGFloat {
            min(width(of: text, font: metrics.itemFont), points * metrics.scale)
        }
        return config.items.compactMap { item in
            guard item.isEnabled else { return nil }
            switch item.kind {
            case .agent:
                // A row that belongs to no session — the pet's own introduction
                // — has no agent to name, and a blank column reads as a bug.
                guard !row.agentName.isEmpty else { return nil }
                // An icon, not the name: "Claude Code" is three quarters of a
                // 112pt pet's panel width, and the name is what the manager's
                // Agents page is for.
                return Item(kind: .agent, primary: row.agentName, secondary: nil,
                            context: nil, width: metrics.iconItemWidth, isFlexible: false,
                            symbolName: AgentGlyph.symbol(for: row.agentID),
                            minimumWidth: metrics.iconItemWidth)
            case .session:
                guard !row.sessionSuffix.isEmpty else { return nil }
                return Item(kind: .session, primary: row.sessionSuffix, secondary: nil,
                            context: nil,
                            width: width(of: row.sessionSuffix, font: metrics.sessionFont),
                            isFlexible: false)
            case .task:
                guard let task = row.task else { return nil }
                return Item(kind: .task, primary: task, secondary: nil, context: nil,
                            width: capped(task, 200), isFlexible: true)
            case .model:
                guard let context = row.context, let label = context.modelLabel else { return nil }
                return Item(kind: .model, primary: label, secondary: nil, context: context,
                            width: capped(label, 160), isFlexible: false)
            case .tool:
                guard let tool = row.tool else { return nil }
                return Item(kind: .tool, primary: tool, secondary: nil, context: nil,
                            width: capped(tool, 130), isFlexible: false)
            case .context:
                guard let context = row.context, let label = usageLabel(context) else { return nil }
                let hasBar = usageFraction(context) != nil
                let barAndGap: CGFloat = hasBar ? metrics.contextBarSize.width + 5 * metrics.scale : 0
                return Item(kind: .context, primary: label, secondary: nil, context: context,
                            width: barAndGap + width(of: label, font: metrics.itemFont),
                            isFlexible: false)
            case .cost:
                guard let label = row.context?.costLabel else { return nil }
                return Item(kind: .cost, primary: label, secondary: nil, context: row.context,
                            width: width(of: label, font: metrics.itemFont), isFlexible: false)
            case .limits:
                guard let limits = row.context?.limitsLabel else { return nil }
                return Item(kind: .limits, primary: limits, secondary: nil, context: row.context,
                            width: capped(limits, 200), isFlexible: false)
            case .message:
                guard let message = row.message else { return nil }
                // The wording never goes under, at any text size: the label is
                // what the item is for, and the ellipsis is what the cut-off
                // detail costs. It is also what the panel is sized to, plus
                // room for the detail — the allowance when there is that much
                // detail, and only what there is when there is less. Sizing the
                // panel to the full allowance whatever the message says leaves
                // a hole at the right of a row whose detail is short or absent,
                // which is what "Running" is (user report, 2026-09-18).
                let wording = width(of: message.label + "…", font: metrics.messageFont)
                let full = message.body.map { "\(message.label) — \($0)" } ?? message.label
                let detail = width(of: full, font: metrics.messageFont)
                    - width(of: message.label, font: metrics.messageFont)
                return Item(kind: .message, primary: message.label, secondary: message.body,
                            context: nil,
                            width: min(width(of: full, font: metrics.messageFont),
                                       metrics.messageWidthCap),
                            fitWidth: wording
                                + min(metrics.messageDetailAllowance, max(0, detail)),
                            isFlexible: true,
                            minimumWidth: metrics.minimumItemWidth / 2,
                            preferredWidth: wording)
            }
        }
    }

    /// The percentage to show, or a token count when a percentage cannot be
    /// worked out honestly.
    static func usageLabel(_ context: SessionContext) -> String? {
        if let fraction = usageFraction(context) {
            return "\(Int((fraction * 100).rounded()))%"
        }
        if let tokens = context.totalTokens { return compact(tokens) }
        return nil
    }

    /// Used fraction, 0...1, or nil when it is not knowable.
    ///
    /// Claude Code's own number is preferred — it knows the window size for
    /// whatever model the gateway is actually serving. The fallback computes
    /// from tokens only when a window size came along, because dividing by a
    /// window we guessed would be a number that looks authoritative and is not.
    static func usageFraction(_ context: SessionContext) -> Double? {
        if let percent = context.usedPercent {
            return min(max(percent / 100, 0), 1)
        }
        guard let tokens = context.totalTokens, let window = context.windowSize, window > 0 else {
            return nil
        }
        return min(max(Double(tokens) / Double(window), 0), 1)
    }

    static func compact(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        }
        if tokens >= 1_000 {
            return "\(tokens / 1_000)k"
        }
        return "\(tokens)"
    }

    // MARK: - Rows

    /// The last layout built, kept for the next caller.
    ///
    /// `plan` is asked for on every frame — the window sizes itself from it
    /// sixty times a second — and building one measures the text of every item
    /// in every row. The panel and its configuration change on the scale of an
    /// event, not of a frame, so one remembered layout is enough to keep the
    /// frame loop out of text measurement entirely.
    private static var remembered: (
        panel: MessagePanel, config: MessagePanelConfig, petWidth: CGFloat, plan: Plan
    )?

    static func plan(for panel: MessagePanel, config: MessagePanelConfig, petWidth: CGFloat) -> Plan {
        if let remembered, remembered.panel == panel, remembered.config == config,
           remembered.petWidth == petWidth {
            return remembered.plan
        }
        let plan = build(panel, config, petWidth)
        remembered = (panel, config, petWidth, plan)
        return plan
    }

    private static func build(
        _ panel: MessagePanel,
        _ config: MessagePanelConfig,
        _ petWidth: CGFloat
    ) -> Plan {
        let metrics = Self.metrics(for: config, petWidth: petWidth)
        let rows = panel.rows.map { row in
            Row(id: row.id, isFocused: row.isFocused,
                items: items(for: row, config: config, petWidth: petWidth))
        }.filter { !$0.items.isEmpty }

        let natural = columns(for: rows, config: config)
        // What the panel would be if it were exactly its content: the columns
        // it would draw, plus the chrome around them.
        let fitted = metrics.padding * 2
            + natural.map(\.fitWidth).reduce(0, +)
            + metrics.spacing * CGFloat(max(0, natural.count - 1))
        let maximum = maximumPanelWidth(for: config, petWidth: petWidth)
        // Never narrower than the pet it points at, never wider than the
        // settings allow. With the fit switched off the panel is the maximum,
        // which is what it has always been.
        let width = config.fitsText ? min(max(fitted, petWidth), maximum) : maximum

        return Plan(rows: rows,
                    columns: filled(squeezed(natural, into: width, metrics: metrics),
                                    into: width, metrics: metrics),
                    alignment: config.alignment, metrics: metrics, width: width)
    }

    /// Spread any room the squeeze could not.
    ///
    /// A panel wider than what the columns want — the fit off, so it is the
    /// settings' maximum, or a pet wider than what is drawn — would otherwise
    /// keep the surplus as a hole at the right of every row, which reads as a
    /// panel that did not bother to fill itself (user report, 2026-09-18).
    ///
    /// It goes back into the columns, each by its share of them, so the table
    /// spans the panel the way it looks like it should: the columns are still
    /// shared, so every row's items start in the same place, but the row ends
    /// at the right edge rather than at the last word. The message's detail is
    /// a case of this rather than a special case — it is the column with the
    /// most room to use, so it gets the most of the surplus.
    private static func filled(
        _ columns: [Column],
        into width: CGFloat,
        metrics: Metrics
    ) -> [Column] {
        var columns = columns
        let budget = max(0, width - metrics.padding * 2
            - metrics.spacing * CGFloat(max(0, columns.count - 1)))
        let drawn = columns.indices.filter { columns[$0].isDrawn }
        let total = drawn.map { columns[$0].width }.reduce(0, +)
        let slack = budget - total
        guard slack > 0.5, total > 0 else { return columns }

        var spent: CGFloat = 0
        for (position, index) in drawn.enumerated() {
            // The last column takes the rounding, so the row lands exactly on
            // the panel's edge rather than a fraction short of it.
            let share = position == drawn.count - 1
                ? slack - spent
                : (slack * columns[index].width / total).rounded(.down)
            columns[index].width += share
            spent += share
        }
        return columns
    }

    /// One column per enabled item kind that at least one row carries.
    ///
    /// A kind nobody carries right now — a tool while nothing is working — is
    /// not a column at all: it is not a blank one either, or every panel would
    /// reserve a slot for a tool that may never appear.
    static func columns(for rows: [Row], config: MessagePanelConfig) -> [Column] {
        config.items.filter(\.isEnabled).compactMap { configured in
            let cells = rows.compactMap { row in row.items.first { $0.kind == configured.kind } }
            guard let first = cells.first else { return nil }
            let fit = cells.map(\.fitWidth).max() ?? first.fitWidth
            return Column(
                kind: configured.kind,
                isFlexible: cells.contains(where: \.isFlexible),
                fitWidth: fit,
                wantedWidth: cells.map(\.width).max() ?? first.width,
                minimumWidth: cells.map(\.minimumWidth).max() ?? first.minimumWidth,
                preferredWidth: cells.map(\.preferredWidth).max() ?? first.preferredWidth,
                width: fit
            )
        }
    }

    /// Fit the columns into the panel's width, then hand back any room to
    /// spare — once for the panel's columns, so every row gets the same
    /// answer, and in the order the row gives things up in.
    private static func squeezed(
        _ columns: [Column],
        into width: CGFloat,
        metrics: Metrics
    ) -> [Column] {
        var columns = columns
        let budget = max(0, width - metrics.padding * 2
            - metrics.spacing * CGFloat(max(0, columns.count - 1)))
        let natural = columns.map(\.width).reduce(0, +)

        guard natural > budget else {
            // Room to spare: the flexible columns take it, up to what they
            // would draw with all the space in the world — the rest of a
            // task's name, the detail under a status wording.
            var slack = budget - natural
            for index in columns.indices where columns[index].isFlexible && slack > 0 {
                let room = max(0, columns[index].wantedWidth - columns[index].width)
                let give = min(room, slack)
                columns[index].width += give
                slack -= give
            }
            return columns
        }

        // The row gives room up in this order, most expendable first:
        //
        //   1. the message's detail — the preview under its wording, which is
        //      the one thing in the panel that is a bonus rather than content;
        //   2. the columns that only name things — session id, model, tool,
        //      usage figure, cost, limits;
        //   3. the task's name;
        //   4. and last the message's own wording, which the all-or-nothing
        //      floor refuses to give up until the row truly cannot pay.
        //
        // Taking it from the flexible columns in list order is what made
        // widening the panel useless: the task paid first and stayed "proj…"
        // while every extra point went to the message's detail (user report,
        // 2026-09-18).
        var deficit = natural - budget
        let minimums = columns.map(\.minimumWidth).reduce(0, +)

        for index in columns.indices where deficit > 0 && columns[index].kind == .message {
            let column = columns[index]
            // The wording, when the row can pay for it whole: what is left
            // once every other column holds its minimum. Paying part of it
            // buys nothing — the wording is cut anyway — so a claim that
            // cannot be paid in full falls back to the floor the message has
            // always had.
            let affordable = budget - (minimums - column.minimumWidth)
            let floor = column.preferredWidth <= affordable ? column.preferredWidth
                                                          : metrics.minimumItemWidth
            let take = min(max(0, columns[index].width - floor), deficit)
            columns[index].width -= take
            deficit -= take
        }
        for index in columns.indices where deficit > 0 && !columns[index].isFlexible {
            let take = min(max(0, columns[index].width - columns[index].minimumWidth), deficit)
            columns[index].width -= take
            deficit -= take
        }
        for index in columns.indices
        where deficit > 0 && columns[index].isFlexible && columns[index].kind != .message {
            let take = min(max(0, columns[index].width - metrics.minimumItemWidth), deficit)
            columns[index].width -= take
            deficit -= take
        }
        // A row narrow enough that even those floors do not fit: everything
        // gives down to the width it would be dropped under.
        for index in columns.indices where deficit > 0 {
            let take = min(max(0, columns[index].width - columns[index].minimumWidth), deficit)
            columns[index].width -= take
            deficit -= take
        }
        return columns
    }


    /// Where each of a row's items is drawn, given the panel's columns.
    ///
    /// The columns are shared, so an item sits in the same place in every row:
    /// its x is the sum of the columns before it. A row with nothing for a
    /// column leaves the cell blank — the columns after it do not move up.
    ///
    /// Text is always left-aligned. The panel's own `alignment` says where the
    /// panel sits relative to the pet, not how the text inside it is set.
    static func frames(
        for row: Row,
        columns: [Column],
        metrics: Metrics
    ) -> [(item: Item, frame: CGRect)] {
        var frames: [(item: Item, frame: CGRect)] = []
        var x = metrics.padding
        for column in columns where column.isDrawn {
            if let item = row.items.first(where: { $0.kind == column.kind }) {
                frames.append((item, CGRect(x: x, y: 0, width: column.width,
                                            height: metrics.rowHeight)))
            }
            x += column.width + metrics.spacing
        }
        return frames
    }

    // MARK: - Measuring

    static func width(of text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }
}
