import SwiftUI

/// A System Settings row: coloured tile, title and subtitle, controls on the trailing edge.
struct SettingRow<Trailing: View>: View {
    let symbol: String
    let color: Color
    let title: String
    var subtitle: String?
    var info: String?
    var status: SourceStatus?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            IconTile(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                    if let status {
                        Circle().fill(status.color).frame(width: 6, height: 6)
                            .help(status.summary)
                            .accessibilityLabel(status.summary)
                    }
                }
                .accessibilityElement(children: .combine)
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            if let info {
                SettingInfo(title: title) { Text(info).foregroundStyle(.secondary) }
            }
            HStack(spacing: 10) { trailing }
        }
    }
}

extension SettingRow where Trailing == Switch {
    init(symbol: String, color: Color, title: String, subtitle: String? = nil, info: String? = nil, isOn: Binding<Bool>) {
        self.init(symbol: symbol, color: color, title: title, subtitle: subtitle, info: info) { Switch(isOn: isOn, label: title) }
    }
}

struct Switch: View {
    @Binding var isOn: Bool
    var label = ""
    var body: some View { Toggle(label, isOn: $isOn).labelsHidden() }
}

/// Shared help for every settings tab; essential state stays in the row.
struct SettingInfo<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @Local private var presented = false

    var body: some View {
        Button { presented.toggle() } label: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) information")
        .help("\(title) information")
        .popover(isPresented: $presented) {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.headline)
                content
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
            .frame(width: 300)
        }
    }
}
