import AgentPetCore
import AppKit
import SwiftUI

struct SettingsView: View {

    @ObservedObject var model: AgentPetModel
    @State private var launchAtLogin = LaunchAtLogin.state

    var body: some View {
        Form {
            Section("Pet") {
                LabeledContent("Size") {
                    HStack(spacing: 8) {
                        Slider(value: petWidthBinding,
                               in: AppConfig.PetConfig.minimumWidth...AppConfig.PetConfig.maximumWidth,
                               step: 4)
                            .frame(minWidth: 120)
                        TextField("", value: petWidthBinding,
                                  format: .number.precision(.fractionLength(0)))
                            .frame(width: 46)
                            .multilineTextAlignment(.trailing)
                        Text("pt")
                        Stepper("", value: petWidthBinding,
                                in: AppConfig.PetConfig.minimumWidth...AppConfig.PetConfig.maximumWidth,
                                step: 4)
                            .labelsHidden()
                    }
                }
                .help("How big the pet is drawn, in points across — Codex's own slider "
                      + "runs 80–224 and defaults to 112, and this is the same range. "
                      + "The sprite keeps its own proportions, the panel is a percentage "
                      + "of this width, and the message's text follows it.")
                Toggle("Animate the pet", isOn: binding(\.pet.animationEnabled))
                Toggle("Keep the pet above other windows", isOn: binding(\.pet.alwaysOnTop))
                Toggle("Respect Reduce Motion", isOn: binding(\.pet.respectsReduceMotion))
                    .help("When the system asks apps to reduce motion, hold the pet on its idle frame.")
            }

            Section("Agents") {
                Toggle("Configure new agents automatically",
                       isOn: binding(\.agents.autoConfigureNewAgents))
                    .help("Off by default: software that edits agent configuration without asking is software you cannot trust.")
            }

            messagePanelSection

            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin.isOn },
                    set: { newValue in
                        launchAtLogin = LaunchAtLogin.setEnabled(newValue)
                    }
                ))
                if let explanation = launchAtLogin.explanation {
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Diagnostics") {
                Toggle("Keep a state transition log", isOn: binding(\.diagnostics.loggingEnabled))
                HStack {
                    Button("Export Diagnostics…") { exportDiagnostics() }
                    Text("Contains versions, integration status, and state transitions. Never prompts, model output, credentials, or source.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Reveal Support Folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            BridgeSocketLocation.applicationSupportDirectory
                        ])
                    }
                    Text(BridgeSocketLocation.applicationSupportDirectory.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = LaunchAtLogin.state }
    }

    // MARK: - Message panel

    private var messagePanelSection: some View {
        Section("Pet message panel") {
            Toggle("Always show the panel", isOn: binding(\.messagePanel.alwaysVisible))
                .help("On: the panel is there whenever a session is known. "
                      + "Off: it appears only while something is actually happening.")

            Toggle("Scale the panel with the pet", isOn: binding(\.messagePanel.autoScale))
                .help("On: the panel draws itself at the default text size for whatever "
                      + "pet size is set, and asks for the default width, so text, rows, "
                      + "glyph and ring keep their proportions as the pet grows. The width "
                      + "and text size below are then set for you and do not apply.")

            LabeledContent("Width") {
                HStack(spacing: 8) {
                    Slider(value: widthPercentBinding,
                           in: MessagePanelConfig.minimumWidthPercent...MessagePanelConfig.maximumWidthPercent,
                           step: 5)
                        .frame(minWidth: 120)
                    TextField("", value: widthPercentBinding, format: .number.precision(.fractionLength(0)))
                        .frame(width: 46)
                        .multilineTextAlignment(.trailing)
                    Text("%")
                    Stepper("", value: widthPercentBinding,
                            in: MessagePanelConfig.minimumWidthPercent...MessagePanelConfig.maximumWidthPercent,
                            step: 5)
                        .labelsHidden()
                }
            }
            .disabled(model.config.messagePanel.autoScale)
            .help("The panel's maximum width, as a percentage of the pet's own width: "
                  + "200% is twice the pet at the default text size, 300% three times "
                  + "it — and the text size scales the whole panel on top of that. With "
                  + "\"Fit the panel to its content\" on, the panel is only drawn this "
                  + "wide when a row actually needs it.")

            Toggle("Fit the panel to its content", isOn: binding(\.messagePanel.fitsText))
                .help("On: the panel is as wide as its widest row needs and no wider — "
                      + "sharing one set of columns, never wider than the maximum above, "
                      + "never narrower than the pet. Off: it is always the maximum.")

            LabeledContent("Text size") {
                HStack(spacing: 8) {
                    Slider(value: messageFontSizeBinding,
                           in: MessagePanelConfig.minimumFontSize...MessagePanelConfig.maximumFontSize,
                           step: 0.5)
                        .frame(minWidth: 120)
                    TextField("", value: messageFontSizeBinding,
                              format: .number.precision(.fractionLength(1)))
                        .frame(width: 46)
                        .multilineTextAlignment(.trailing)
                    Text("pt")
                    Stepper("", value: messageFontSizeBinding,
                            in: MessagePanelConfig.minimumFontSize...MessagePanelConfig.maximumFontSize,
                            step: 0.5)
                        .labelsHidden()
                }
            }
            .disabled(model.config.messagePanel.autoScale)
            .help("The panel's text, in points at the default 112pt pet. Everything "
                  + "the panel draws with scales together — the status wording, the "
                  + "session's names, the agent's glyph, the usage ring, the row, the "
                  + "padding — and the panel and its window grow with it, so a bigger "
                  + "text size zooms the panel rather than squeezing a bigger message "
                  + "into the same box.")

            Text(effectiveSizeSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Align", selection: binding(\.messagePanel.alignment)) {
                ForEach(MessagePanelConfig.Alignment.allCases) { alignment in
                    Text(alignment.title).tag(alignment)
                }
            }
            .pickerStyle(.segmented)
            .help("Where the panel sits relative to the pet: Left puts the panel's left "
                  + "edge on the pet's left edge, Right its right edge on the pet's right "
                  + "edge, Centre centres it over the pet. The text inside is always "
                  + "left-aligned, and the pet itself does not move.")

            ForEach(Array(model.config.messagePanel.items.enumerated()), id: \.element.kind) { index, item in
                HStack(spacing: 8) {
                    Toggle(item.kind.title, isOn: itemEnabledBinding(index))
                        .help(item.kind.explanation)
                    Spacer()
                    Button {
                        moveItem(from: index, by: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == 0)
                    .help("Move left")
                    Button {
                        moveItem(from: index, by: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == model.config.messagePanel.items.count - 1)
                    .help("Move right")
                }
            }

            HStack {
                Text(contextTapSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                switch model.contextTap {
                case .notInstalled:
                    Button("Enable Context Usage…") { model.enableContextTap() }
                case .installed:
                    Button("Stop Using the Status Line") { model.disableContextTap() }
                case .drifted:
                    Button("Re-enable Context Usage…") { model.enableContextTap() }
                }
            }

            HStack {
                Text(grokContextTapSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                switch model.grokContextTap {
                case .notInstalled:
                    Button("Enable Grok Context…") { model.enableGrokContextTap() }
                case .installed:
                    Button("Stop Feeding Grok Context") { model.disableGrokContextTap() }
                case .drifted:
                    Button("Re-enable Grok Context…") { model.enableGrokContextTap() }
                }
            }

            HStack {
                Text(antigravityContextTapSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                switch model.antigravityContextTap {
                case .notInstalled:
                    Button("Enable Antigravity Context…") { model.enableAntigravityContextTap() }
                case .installed:
                    Button("Stop Feeding Antigravity Context") { model.disableAntigravityContextTap() }
                case .drifted:
                    Button("Re-enable Antigravity Context…") { model.enableAntigravityContextTap() }
                }
            }
        }
        .onAppear {
            model.refreshContextTap()
            model.refreshGrokContextTap()
            model.refreshAntigravityContextTap()
        }
    }

    private var contextTapSummary: String {
        switch model.contextTap {
        case .notInstalled:
            return "Model, context, cost, and rate limits are not available yet: Claude Code "
                + "reports them only to its status line. Enabling wraps your status line — "
                + "the runtime reads those numbers, then runs your own command unchanged. "
                + "It takes effect immediately, and removing it puts your command back."
        case .installed(let original):
            return original == nil || original!.isEmpty
                ? "Reading model, context, cost, and rate limits from Claude Code’s status line."
                : "Reading model, context, cost, and rate limits from Claude Code’s status line, "
                + "and running yours through it unchanged."
        case .drifted:
            return "The status line in ~/.claude/settings.json is no longer the one the runtime "
                + "installed — something else changed it. Re-enabling wraps whatever is there now."
        }
    }

    private var grokContextTapSummary: String {
        switch model.grokContextTap {
        case .notInstalled:
            return "Grok reports model, context, and cost only to its status line. "
                + "Enabling adds one section to ~/.grok/config.toml that feeds the runtime "
                + "and prints nothing — nothing appears in your terminal."
        case .installed:
            return "Reading model, context, and cost from Grok’s status line. "
                + "The row itself stays hidden."
        case .drifted:
            return "The [ui.status_line] section in ~/.grok/config.toml is no longer the one "
                + "the runtime installed — something else changed it. Re-enabling installs "
                + "the runtime’s block again."
        }
    }

    private var antigravityContextTapSummary: String {
        switch model.antigravityContextTap {
        case .notInstalled:
            return "Antigravity reports model, context, and cost only to its status line. "
                + "Enabling replaces the built-in row with a plain one that feeds the "
                + "runtime — the terminal keeps a status line, just a simpler one."
        case .installed:
            return "Reading model, context, and cost from Antigravity’s status line, "
                + "which shows a plain replacement row."
        case .drifted:
            return "The status line in ~/.gemini/antigravity-cli/settings.json is no longer "
                + "the one the runtime installed — something else changed it. Re-enabling "
                + "installs the runtime’s command again."
        }
    }

    private var widthPercentBinding: Binding<Double> {
        Binding(
            get: { model.config.messagePanel.widthPercent },
            set: { newValue in
                model.config.messagePanel.widthPercent = MessagePanelConfig.clampWidth(newValue)
                model.saveConfig()
            }
        )
    }

    private var petWidthBinding: Binding<Double> {
        Binding(
            get: { model.config.pet.width },
            set: { newValue in
                model.config.pet.width = AppConfig.PetConfig.clampWidth(newValue)
                model.saveConfig()
            }
        )
    }

    private var messageFontSizeBinding: Binding<Double> {
        Binding(
            get: { model.config.messagePanel.messageFontSize },
            set: { newValue in
                model.config.messagePanel.messageFontSize =
                    MessagePanelConfig.clampFontSize(newValue)
                model.saveConfig()
            }
        )
    }

    /// What the size settings mean at the pet size on screen now — the
    /// numbers the sliders alone cannot tell you, and the size every label,
    /// glyph and ring in the panel is drawn at.
    private var effectiveSizeSummary: String {
        let petWidth = CGFloat(model.config.pet.width)
        let points = MessagePanelLayout.effectiveFontSize(for: model.config.messagePanel)
            * model.config.pet.width / AppConfig.PetConfig.defaultWidth
        let drawn = points.formatted(.number.precision(.fractionLength(1)))
        let widest = Int(MessagePanelLayout.maximumPanelWidth(
            for: model.config.messagePanel, petWidth: petWidth
        ))
        let pet = Int(model.config.pet.width)
        return model.config.messagePanel.autoScale
            ? "Scaled with the pet: the text draws at \(drawn) pt with a \(pet)pt pet, "
                + "and the panel may be up to \(widest)pt wide."
            : "The panel's text draws at \(drawn) pt with a \(pet)pt pet, "
                + "up to \(widest)pt wide."
    }

    private func itemEnabledBinding(_ index: Int) -> Binding<Bool> {
        Binding(
            get: {
                guard model.config.messagePanel.items.indices.contains(index) else { return false }
                return model.config.messagePanel.items[index].isEnabled
            },
            set: { newValue in
                guard model.config.messagePanel.items.indices.contains(index) else { return }
                model.config.messagePanel.items[index].isEnabled = newValue
                model.saveConfig()
            }
        )
    }

    private func moveItem(from index: Int, by offset: Int) {
        let target = index + offset
        var items = model.config.messagePanel.items
        guard items.indices.contains(index), items.indices.contains(target) else { return }
        items.swapAt(index, target)
        model.config.messagePanel.items = items
        model.saveConfig()
    }

    /// Settings are written on change, so there is no Save button to forget.
    private func binding<T>(_ keyPath: WritableKeyPath<AppConfig, T>) -> Binding<T> {
        Binding(
            get: { model.config[keyPath: keyPath] },
            set: { newValue in
                model.config[keyPath: keyPath] = newValue
                model.saveConfig()
            }
        )
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "agent-pet-diagnostics.json"
        panel.message = "Save a diagnostics bundle to share with a bug report"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.exportDiagnostics(to: url)
    }
}
