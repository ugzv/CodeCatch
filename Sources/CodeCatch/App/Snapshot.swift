#if DEBUG
import AppKit
import CodeCatchCore
import SwiftUI

/// `CodeCatch --snapshot <dir> -autoCopy NO -showHUD NO`: renders the real views with
/// sample codes to PNGs, light and dark, for checking layout without screen recording.
@MainActor
enum Snapshot {
    static func run(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        Prefs.register()
        Secrets.offline = true
        UserDefaults.standard.removeObject(forKey: Prefs.clearedAt)  // the empty-state render below clears history
        Glass.useMaterial = CommandLine.arguments.contains("-material")
        let model = AppModel.shared
        let samples: [(String, String, String, TimeInterval, Bool)] = [
            ("G-482913 is your Google verification code.", "", "22000", 30, false),
            ("Your Scrape.do Login Verification Code: 889687", "Scrape.do Team", "noreply@scrape.do", 1200, true),
            ("Koda za prijavo v naročniški center Moj Zabec: 20553106", "Zabec.net", "info@zabec.net", 5400, true),
            ("Revolut: Your code is 771 204. Never share it", "", "Revolut", 11000, false),
            ("OTP banka: Enkratno geslo za nakup pri ZALANDO SE v znesku 89,90 EUR s kartico *4821 je 318842.", "", "OTPbanka", 26 * 3600, false),
            ("OTP banka: Enkratno geslo za nakup pri BOLT.EU v znesku 12,40 EUR s kartico *4821 je 604719.", "", "OTPbanka", 28 * 3600, false),
        ]
        for (text, name, sender, age, mail) in samples {
            model.ingest(IncomingMessage(text: text, senderName: name, senderID: sender, sourceKey: mail ? "m" : MessagesStore.sourceKey,
                                         sourceLabel: mail ? "Work" : "Messages", date: Date().addingTimeInterval(-age), isMail: mail))
        }
        model.ingest(IncomingMessage(text: "We've detected an unusual sign-in to your Ahrefs account.", subject: "Confirm your sign-in",
                                     senderName: "Ahrefs Support", senderID: "support@ahrefs.com", sourceKey: "m", sourceLabel: "Work",
                                     date: Date().addingTimeInterval(-40), isMail: true,
                                     links: [MailLink(url: "https://app.ahrefs.com/verify-yourself/example-token", label: "Sign in with a verified link")]))
        model.ingest(IncomingMessage(text: "Confirm it was you.", subject: "Verify your sign-in", senderName: "Acme", senderID: "security@acme.com",
                                     sourceKey: "m", sourceLabel: "Personal", date: Date().addingTimeInterval(-10), isMail: true,
                                     links: [MailLink(url: "https://acme-secure-login.net/verify?t=1", label: "Verify sign-in")]))
        for item in model.items { _ = IconStore.shared.icon(for: item.domain) }
        RunLoop.main.run(until: Date().addingTimeInterval(10))  // let the logos arrive
        let id = model.items.first!.id
        for (scheme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            render(AnyView(BannerCard(id: id).padding(20)), "hud-\(scheme)", appearance, dir)
            render(AnyView(BannerCard(id: model.items[2].id).padding(20)), "hud-mail-\(scheme)", appearance, dir)
            render(AnyView(MenuContent()), "menu-\(scheme)", appearance, dir)
            render(AnyView(SettingsView()), "settings-\(scheme)", appearance, dir)
            render(AnyView(WelcomeView()), "welcome-\(scheme)", appearance, dir)
            render(AnyView(SourcesTab().frame(width: 560, height: 600)), "sources-\(scheme)", appearance, dir)
            render(AnyView(GeneralTab().frame(width: 560, height: 600)), "general-\(scheme)", appearance, dir)
            render(AnyView(PrivacyTab().frame(width: 560, height: 600)), "privacy-\(scheme)", appearance, dir)
            render(AnyView(AddAccountSheet() { _ in }), "add-account-\(scheme)", appearance, dir)
            render(AnyView(AccountEditor(account: MailAccount.guess(for: "you@example.com"))), "account-editor-\(scheme)", appearance, dir)
        }
        let blurred = ImageRenderer(content: CodeText(code: "482913", size: 36, concealed: true).padding(12).background(Color.white))
        blurred.scale = 2
        try? blurred.nsImage?.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }?
            .write(to: URL(fileURLWithPath: "\(dir)/code-blurred.png"))
        let empty = AnyView(MenuContent())
        model.clearHistory()
        render(empty, "menu-empty", .aqua, dir)
    }

    private static func render(_ view: AnyView, _ name: String, _ appearance: NSAppearance.Name, _ dir: String) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 600, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = appearance == .darkAqua ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)
        window.contentView = host
        host.frame.size = host.fittingSize
        window.setContentSize(host.fittingSize)
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        window.orderOut(nil)
    }
}
#endif
