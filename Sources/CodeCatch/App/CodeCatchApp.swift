import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        #if DEBUG
        if args.contains("--preview-recovery") {
            MainActor.assumeIsolated { RecoveryPreview.run() }
            exit(0)
        }
        if let i = args.firstIndex(of: "--snapshot") {
            guard i + 1 < args.count else { print("Usage: CodeCatch --snapshot <directory>"); exit(1) }
            MainActor.assumeIsolated { Snapshot.run(to: args[i + 1]) }
            exit(0)
        }
        #endif
        // Snapshots must never migrate real credentials; imports must follow migration.
        Secrets.migrateFile()
        #if DEBUG
        if let i = args.firstIndex(of: "--import-env") {
            guard i + 1 < args.count else { print("Usage: CodeCatch --import-env <path/to/.env>"); exit(1) }
            var accounts = MailAccount.load()
            let path = args[i + 1]
            do {
                let n = try EnvImport.importCredentials(from: path, into: &accounts)
                MailAccount.save(accounts)
                print("Imported \(n) password(s)")
                exit(0)
            } catch {
                print("Import failed: \(error.localizedDescription)")
                exit(1)
            }
        }
        if let probe = Probe.all.first(where: { args.contains($0.key) })?.value {
            Task { await probe(); exit(0) }
            dispatchMain()
        }
        #endif
        // One menu bar icon: a second copy (the DMG's, or another install) bows out.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != .current }) { exit(0) }
        CodeCatchApp.main()
    }
}

struct CodeCatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }

        Window("Find a Code", id: "recovery") {
            RecoveryView(model: AppModel.shared)
        }
        .defaultSize(width: 700, height: 450)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Welcome", id: WelcomeView.windowID) {
            WelcomeView()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(Prefs[Prefs.welcomed] ? .suppressed : .presented)
        .restorationBehavior(.disabled)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.start()
            _ = Updater.controller  // starts the scheduled update checks
        }
    }

    /// codecatch:// links. SwiftUI keeps `application(_:open:)` for its own scenes, so take the event directly.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(openURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func openURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let url = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue.flatMap(URL.init(string:)) else { return }
        MainActor.assumeIsolated { MenuBarPopover.handle(url) }
    }
}
