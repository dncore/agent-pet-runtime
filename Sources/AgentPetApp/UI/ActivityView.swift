import AgentPetCore
import SwiftUI

/// Activity Center — every live session, and which one the pet is showing.
struct ActivityView: View {

    @ObservedObject var model: AgentPetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.activities.isEmpty {
                emptyState
            } else {
                List(model.activities) { activity in
                    row(activity)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No agent sessions")
                .foregroundStyle(.secondary)
            Text("Run a configured agent, or send a test event from the Agents tab.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func row(_ activity: AgentActivity) -> some View {
        HStack(spacing: 10) {
            Image(systemName: AgentGlyph.symbol(for: activity.agentID))
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityLabel(activity.agentID)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(activity.agentID).fontWeight(.medium)
                    if activity.id == model.focusedActivityID {
                        Text("showing")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.tint.opacity(0.2), in: Capsule())
                    }
                }
                HStack(spacing: 6) {
                    Text(activity.sessionID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let title = activity.title {
                        Text("·").foregroundStyle(.tertiary)
                        Text(title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            // Confidence is shown because process-observation states are
            // guesses, and the user should be able to tell them apart from
            // what a hook actually reported.
            if activity.confidence.level != .high {
                Text(activity.confidence.level.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.orange.opacity(0.12), in: Capsule())
                    .help("Inferred from \(activity.confidence.source), not reported by the agent")
            }

            Text(activity.state.rawValue)
                .font(.caption)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(stateColor(activity.state).opacity(0.18), in: Capsule())
                .foregroundStyle(stateColor(activity.state))

            Text(relative(activity.updatedAt))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .trailing)

            // A test session is the one kind of activity that can be ended
            // from here; everything else is owned by an agent that is still
            // running.
            if model.isTestActivity(activity) {
                Button {
                    model.stopTest()
                } label: {
                    Image(systemName: "stop.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Stop this test")
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { model.focus(activity) }
        .help(activity.focusTarget?.path.map { "Open \($0)" } ?? "No location known for this session")
    }

    private func stateColor(_ state: AgentState) -> Color {
        switch state.priorityClass {
        case .attention: return .orange
        case .failure:   return .red
        case .active:    return .green
        case .settled:   return .blue
        case .inactive:  return .secondary
        }
    }

    private func relative(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
}
