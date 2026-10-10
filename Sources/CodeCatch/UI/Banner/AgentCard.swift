import AppKit
import CodeCatchCore
import SwiftUI

/// The card a `codecatch` request shows. Its own panel, apart from the code banner, so an arriving
/// code can never swap the card under the user's pointer.
@MainActor
enum AgentPanel {
    private static let panel: NSPanel = {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return p
    }()
    private static var hideTask: Task<Void, Never>?

    static func present(_ presentation: AgentAccess.Presentation) {
        hideTask?.cancel()
        switch presentation {
        case .card:
            Banner.shared.hide()
            show(AnyView(AgentRequestCard()))
            NSSound(named: "Tink")?.play()
        case .notice(let item, let caller, let rule):
            show(AnyView(AgentNotice(item: item, caller: caller, rule: rule)))
            hideTask = Task {
                try? await Task.sleep(for: .seconds(6))
                if !Task.isCancelled { panel.orderOut(nil) }
            }
        case .hide:
            panel.orderOut(nil)
        }
    }

    private static func show(_ view: AnyView) {
        panel.sharingType = Prefs[Prefs.hideFromCapture] ? .none : .readOnly
        let host = FirstClickHostingView(rootView: view)
        panel.contentView = host
        let size = host.fittingSize
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrame(NSRect(x: frame.maxX - size.width, y: frame.maxY - size.height + 2, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }
}

/// "iTerm2 wants your github.com code". Every line comes from CodeCatch's own data — the verified
/// app, the message's sender, the times — never from text the agent sent. The code itself isn't shown.
struct AgentRequestCard: View {
    @ObservedObject private var access = AppModel.shared.agents
    @ObservedObject private var model = AppModel.shared
    /// Buttons wait a moment after the card appears, so a click meant for something else can't land on Allow.
    @Local private var armed = false

    var body: some View {
        if let request = access.request, let item = request.item {
            let site = item.domain ?? request.query.label
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    appIcon(request.caller)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(request.unnamed ? "\(request.caller.name) asked for a \(request.query.label) code"
                             : "\(request.caller.name) wants \(item.isLink ? "a \(site) sign-in link" : "your \(site) code")")
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        if request.caller.app != nil {
                            Label("Verified app", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        } else {
                            Label("Not a verified app", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)
                }
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    row("From", "\(item.service) · \(item.origin == .mail ? "Mail" : "Messages")"
                        + (item.sender.isEmpty || item.sender.contains("@") ? "" : " · \(item.sender)")
                        + (item.senderVerified == true ? " · verified sender" : ""))
                    row("Timing", "Asked \(ago(request.asked)), arrived \(ago(item.received))")
                    if !request.caller.process.isEmpty { row("Program", "\(request.caller.process) (name not verified)") }
                }
                .font(.callout)
                if item.isLink {
                    note("This link signs \(request.caller.name) in to \(site) as you.")
                }
                if request.unnamed {
                    note("This text doesn't say which site it is for. Allow it only if you just asked \(request.query.label) for a code.")
                }
                if item.origin == .mail, item.senderVerified != true {
                    note("The sender isn't verified. Check the email before allowing this code.")
                }
                HStack {
                    if request.caller.app != nil, !request.unnamed, !item.isLink,
                       item.origin != .mail || item.senderVerified == true {
                        Menu("Always Allow") {
                            if let domain = item.domain {
                                Button("\(domain) Codes from \(request.caller.name)") { Task { await access.allow(.site) } }
                            }
                            Button("All Codes from \(request.caller.name)") { Task { await access.allow(.allSites) } }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                    Spacer()
                    Button("Deny") { access.deny() }
                    Button("Allow") { Task { await access.allow() } }
                        .buttonStyle(.borderedProminent)
                }
                .disabled(!armed || access.authenticating)
            }
            .padding(16)
            .frame(width: 356)
            .modifier(GlassBackground(shape: RoundedRectangle(cornerRadius: 24, style: .continuous), shadowRadius: 14, shadowY: 6))
            .padding(12)
            .task(id: item.id) {
                armed = false
                try? await Task.sleep(for: .milliseconds(700))
                armed = true
            }
        }
    }

    private func ago(_ date: Date) -> String {
        let s = max(0, Int(model.now.timeIntervalSince(date)))
        return s < 60 ? "\(s)s ago" : "\(s / 60) min ago"
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func note(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// After a release by rule or Allow All: what went where, and a way to stop it.
struct AgentNotice: View {
    let item: CodeItem
    let caller: AgentCaller
    let rule: AgentRule?

    var body: some View {
        HStack(spacing: 10) {
            appIcon(caller)
            VStack(alignment: .leading, spacing: 2) {
                Text("Gave \(item.isLink ? "a \(item.domain ?? item.service) sign-in link" : "your \(item.domain ?? item.service) code") to \(caller.name)")
                    .font(.headline)
                Text(rule.map { $0.site.map { "\($0) is allowed without asking." } ?? "All codes are allowed without asking." } ?? "Allow All is on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(rule == nil ? "Turn Off" : "Stop Allowing") {
                let access = AppModel.shared.agents
                if let rule { access.removeRule(rule.id) } else { Task { await access.setAllowAll(false) } }
                AgentPanel.present(.hide)
            }
        }
        .padding(16)
        .frame(width: 356)
        .modifier(GlassBackground(shape: RoundedRectangle(cornerRadius: 24, style: .continuous), shadowRadius: 14, shadowY: 6))
        .padding(12)
    }
}

@MainActor private func appIcon(_ caller: AgentCaller) -> some View {
    Group {
        if let path = caller.appPath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path.path)).resizable()
        } else {
            Image(systemName: "terminal.fill").resizable().scaledToFit().padding(6).foregroundStyle(.secondary)
        }
    }
    .frame(width: 38, height: 38)
}
