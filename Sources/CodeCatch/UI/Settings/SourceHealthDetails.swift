import SwiftUI

struct SourceHealthDetails: View {
    let health: SourceHealth
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Last checked", value: relative(health.lastChecked))
            LabeledContent("Last message", value: relative(health.lastMessage))
            LabeledContent("Last code", value: relative(health.lastCode))
            if let retryAt = health.retryAt {
                Text("Retrying in \(max(0, Int(ceil(retryAt.timeIntervalSince(now)))))s")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func relative(_ date: Date?) -> String {
        guard let date else { return "not yet" }
        if now.timeIntervalSince(date) < 1 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
