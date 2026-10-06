import AppKit
import SwiftUI

enum SettingsTab: String {
    case general, sources, privacy
    static let storageKey = "settingsTab"
    /// The tab Settings shows when it opens next.
    func select() { UserDefaults.standard.set(rawValue, forKey: Self.storageKey) }
}

extension OpenSettingsAction {
    /// Opens Settings in front, at `tab` when given. A menu-bar app isn't active, so
    /// without activating first Settings opens behind other windows.
    @MainActor func callAsFunction(at tab: SettingsTab?) {
        tab?.select()
        NSApp.activate()
        callAsFunction()
    }
}

struct SettingsView: View {
    @AppStorage(SettingsTab.storageKey) private var selectedTab: SettingsTab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralTab().modifier(SettingsBrandFooter()).tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            SourcesTab().modifier(SettingsBrandFooter()).tabItem { Label("Sources", systemImage: "tray.2") }
                .tag(SettingsTab.sources)
            PrivacyTab().modifier(SettingsBrandFooter()).tabItem { Label("Privacy", systemImage: "hand.raised") }
                .tag(SettingsTab.privacy)
        }
        .frame(width: 560, height: 600)
    }
}

private struct SettingsBrandFooter: ViewModifier {
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                BrandHeading()
                Spacer()
                Menu {
                    Button("About CodeCatch", action: AppBrand.showAbout)
                    Divider()
                    Button("Report a Bug…") { AppBrand.openIssue(.bug) }
                    Button("Suggest a Feature…") { AppBrand.openIssue(.feature) }
                } label: {
                    GlyphLabel(symbol: "questionmark.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("About and feedback")
            }
            .bottomBar()
        }
    }
}
