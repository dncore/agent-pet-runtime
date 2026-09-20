import AgentPetCore
import SwiftUI

/// Agent Integrations — the screen that distinguishes this from a desk toy.
struct AgentsView: View {

    @ObservedObject var model: AgentPetModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Each agent reports its own status. Configuring installs the integration that agent takes — hook lines in its config file, or one extension file — and keeps a backup; removing deletes only the integration the runtime installed, after taking a copy.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // The pass that fills these in spawns a process per agent, and
                // it no longer holds the window up: say so rather than showing
                // a page with nothing on it (user report, 2026-09-18).
                if model.agentStatuses.isEmpty, model.isRefreshingAgents {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking what is installed…")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }

                ForEach(model.agentStatuses) { status in
                    card(for: status)
                }
            }
            .padding(16)
        }
    }

    private func card(for status: AgentStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Circle()
                    .fill(indicatorColor(status.health))
                    .frame(width: 9, height: 9)
                Text(status.displayName).font(.title3).fontWeight(.semibold)
                Text(status.health.displayName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if let version = status.detection.version {
                    Text(version)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                detail("Executable", status.detection.executablePath ?? "not found")
                detail("Configuration", configSummary(status))
                detail("Last event", lastEventSummary(status))
                if let problem = problem(status) {
                    GridRow {
                        Text("Status").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text(problem).foregroundStyle(.orange)
                    }
                }
            }
            .font(.callout)

            if !status.canConfigure, let note = status.profile.configurationNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if status.canConfigure {
                    Button(status.record.isConfigured ? "Reconfigure" : "Configure") {
                        model.configureAgent(status)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                }

                if status.canUninstall {
                    // One button, two jobs: a test that cannot be stopped from
                    // where it was started would be a trap.
                    if model.activeTestAgentID == status.profile.agentID {
                        Button("Stop Test") { model.stopTest() }
                            .help("The test stops on its own after "
                                  + "\(Int(AgentPetModel.testDuration))s anyway")
                    } else {
                        Button("Test") { model.sendTestEvent(agentID: status.profile.agentID) }
                            .help("Sends a synthetic event through the real pipeline. "
                                  + "It stops on its own after \(Int(AgentPetModel.testDuration))s.")
                    }

                    Button("Remove Integration", role: .destructive) {
                        model.removeAgentIntegration(status)
                    }
                }

                Spacer()
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    private func detail(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func configSummary(_ status: AgentStatus) -> String {
        guard status.record.isConfigured else { return "not configured" }
        let count = status.record.entries.count
        switch status.profile.mechanism {
        case .hookTable:
            return "\(count) hook\(count == 1 ? "" : "s") installed"
        case .extensionFile:
            return "extension installed"
        }
    }

    private func lastEventSummary(_ status: AgentStatus) -> String {
        guard let last = status.lastEventAt else { return "none yet" }
        let seconds = Int(Date().timeIntervalSince(last))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return last.formatted(date: .omitted, time: .shortened)
    }

    private func problem(_ status: AgentStatus) -> String? {
        switch status.health {
        case .disconnected:
            switch status.profile.mechanism {
            case .hookTable:
                // Two ways here, and both are fixed by configuring again: the
                // lines are gone, or the file still holds one this version
                // stopped writing (an older launch's, which the automatic
                // migration could not remove because the entry was edited).
                return "The hooks in the config file are not the ones this version writes "
                    + "— configure again to update them."
            case .extensionFile:
                return "The extension the runtime wrote is missing, or no longer matches what it recorded."
            }
        case .failed(let message):
            return message
        case .degraded where status.record.isConfigured:
            // Not "no events recently" — an idle agent is silent, and saying
            // otherwise made a working setup look broken. This fires only
            // when nothing has ever arrived since the hooks were installed.
            switch status.profile.mechanism {
            case .hookTable:
                return "Hooks are installed, but no event has ever reached the pet. "
                    + "Agents read their hooks at startup, so restart it once."
            case .extensionFile:
                return "\(status.displayName) reads its extensions when a session starts, "
                    + "so the pet appears the next time you start one."
            }
        default:
            return nil
        }
    }

    private func indicatorColor(_ health: IntegrationHealth) -> Color {
        switch health {
        case .connected:    return .green
        case .degraded:     return .yellow
        case .disconnected, .failed: return .orange
        case .detected:     return .blue
        case .notDetected:  return .secondary.opacity(0.4)
        }
    }
}
