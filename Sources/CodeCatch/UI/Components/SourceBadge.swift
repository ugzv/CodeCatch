import SwiftUI

/// Full source status inside the details popover.
struct SourceBadge: View {
    let status: SourceStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(status.color).frame(width: 6, height: 6)
            Text(status.summary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
    }
}

extension SourceStatus {
    var color: Color {
        switch self {
        case .live: .green
        case .connecting: .orange
        case .off: .gray
        case .attention: .orange
        case .failed: .red
        }
    }
}
