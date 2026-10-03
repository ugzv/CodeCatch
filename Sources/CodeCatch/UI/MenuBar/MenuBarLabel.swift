import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject private var model = AppModel.shared
    @AppStorage(Prefs.codeInMenuBar) private var showCode = true
    @AppStorage(Prefs.blurCodes) private var blurCodes = false

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: AppBrand.menuBarImage).accessibilityLabel(AppBrand.name)
            if showCode, !blurCodes, model.isUnlocked, let item = model.latestCode, !item.used, model.now.timeIntervalSince(item.received) < 180 {
                Text(groupedCode(item.code)).monospacedDigit()
            } else if !model.isUnlocked, model.latest != nil {
                Image(systemName: "lock.fill").accessibilityLabel("Locked")
            }
            // The popover explains it; without this a source that can't be read fails silently.
            if model.sources.contains(where: \.status.needsAttention) {
                Image(systemName: "exclamationmark.triangle.fill").accessibilityLabel("A source needs attention")
            }
        }
        .help(AppBrand.name)
    }
}
