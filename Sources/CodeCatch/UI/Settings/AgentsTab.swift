import CodeCatchCore
import SwiftUI

struct AgentsTab: View {
    @ObservedObject private var access = AppModel.shared.agents
    @AppStorage(Prefs.autoCopy) private var autoCopy = true
    @AppStorage(Prefs.autoType) private var autoType = false
    /// What Sources catches: agents can't get what isn't caught.
    @AppStorage(Prefs.receivedCodes) private var catchesCodes = true
    @AppStorage(Prefs.signInLinks) private var catchesLinks = true
    @Local private var tool = CommandLineTool.state
    @Local private var toolError: String?
    @Local private var showingRules = false
    @Local private var copiedAt: Date?
    @Local private var skills: [AgentSkill: AgentSkill.State] = [:]
    private let home = FileManager.default.homeDirectoryForCurrentUser
    @Local private var showingHistory = false

    var body: some View {
        Form {
            Section {
                // One switch: turning it on also installs codecatch, since access is useless without it.
                SettingRow(symbol: "terminal.fill", color: .gray, title: "Let Agents Ask for Codes",
                           subtitle: access.config.enabled && tool == .installed ? "Agents can run codecatch." : nil,
                           info: "Agents such as Claude Code and Codex run codecatch get github.com when a site sends a code. Turning this on installs codecatch in /usr/local/bin. You approve each code with \(DeviceAuthentication.unlockMethods), unless you allowed it below. If you say no three times in a row, this turns off.",
                           isOn: Binding(get: { access.config.enabled }, set: { on in Task { await setEnabled(on) } }))
                if let error = access.error {
                    WarningText(message: error).font(.callout)
                }
                if access.config.enabled, autoCopy || autoType {
                    SettingRow(symbol: "exclamationmark.triangle.fill", color: .orange, title: "Automatic Copy Is On",
                               subtitle: "Any app can read the clipboard.",
                               info: "An agent could read new codes from the clipboard without asking. CodeCatch skips copying while a request waits, but codes that arrive at other times are still copied.") {
                        Button("Turn Off") { autoCopy = false; autoType = false }
                    }
                }
                // Only when something needs a hand: a failed install, a moved app, or a link left behind.
                if let toolSummary {
                    SettingRow(symbol: "chevron.left.forwardslash.chevron.right", color: .indigo, title: "Command-Line Tool", subtitle: toolSummary,
                               info: "codecatch lives in /usr/local/bin so agents can run it by name. They can also use its full path, which is in the instructions.") {
                        switch tool {
                        case .notInstalled: Button("Install…") { change { try CommandLineTool.install(over: tool) } }
                        case .stale: Button("Repair…") { change { try CommandLineTool.install(over: tool) } }
                        case .installed: Button("Remove…") { change { try CommandLineTool.remove(tool) } }
                        case .unavailable, .taken: EmptyView()
                        }
                    }
                }
            } header: {
                Text("Command Line")
            } footer: {
                if !access.config.enabled {
                    Text("Agents can't ask for codes while this is off.").font(.caption).foregroundStyle(.secondary)
                }
            }
            // Connect writes a skill the agent loads only when it needs a code; others get the text to paste.
            Section("Agents") {
                ForEach(AgentSkill.allCases.filter { $0.isInstalled(home: home) }) { agent in
                    AgentSkillRow(agent: agent, state: skills[agent] ?? .notConnected) { skillsChanged() }
                        // Connecting waits for access; removing a skill is cleanup, so Disconnect stays.
                        .disabled(!access.config.enabled && skills[agent] != .connected)
                }
                SettingRow(symbol: "doc.on.doc.fill", color: .blue, title: "Other Agents",
                           info: "For an agent not listed above: paste this into its instructions, such as AGENTS.md.") {
                    // Says "Copied" for a moment, like a code's Copy button.
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(CommandLineTool.instructions, forType: .string)
                        copiedAt = Date()
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            if let at = copiedAt, Date().timeIntervalSince(at) >= 1.4 { copiedAt = nil }
                        }
                    } label: {
                        Text(copiedAt == nil ? "Copy" : "Copied")
                    }
                    .accessibilityLabel(copiedAt == nil ? "Copy instructions" : "Copied")
                }
                // What the agent will read, readable here too, and selectable for copying just a part.
                Text(CommandLineTool.instructions)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.04)))
            }
            // The same rows as Sources → What to Catch: what agents may get of what CodeCatch catches.
            Section("What to Share") {
                SettingRow(symbol: CatchKind.code.symbol, color: CatchKind.code.color, title: "Verification Codes",
                           subtitle: catchesCodes ? nil : "Off in Sources",
                           info: "Agents get codes while Let Agents Ask for Codes is on.") {
                    Text("Included").foregroundStyle(.secondary)
                }
                SettingRow(symbol: CatchKind.signIn.symbol, color: CatchKind.signIn.color, title: "Sign-In Links",
                           subtitle: catchesLinks ? nil : "Off in Sources",
                           info: "A link signs the agent in as you, so this is off until you turn it on. Links go out only from the site’s own verified sender. Turning this on asks for \(DeviceAuthentication.unlockMethods).") {
                    Switch(isOn: Binding(get: { access.config.links }, set: { on in Task { await access.setLinks(on) } }), label: "Sign-In Links")
                        .disabled(!catchesLinks)
                }
                SettingRow(symbol: CatchKind.passwordReset.symbol, color: CatchKind.passwordReset.color, title: "Password Reset Links",
                           info: "A reset link lets whoever opens it take over the account, so agents never get one.") {
                    Text("Never").foregroundStyle(.secondary)
                }
            }
            .disabled(!access.config.enabled)
            Section("Permissions") {
                SettingRow(symbol: "exclamationmark.shield.fill", color: .red, title: "Allow All Without Asking",
                           subtitle: access.config.allowAll ? "Automatic sharing is on." : nil,
                           info: "Any agent can receive codes automatically, and sign-in links too if they are on. Email needs a verified sender; Apple Mail and generic IMAP codes still ask. A text that doesn't name its site also asks. You see each release in a banner and Request History. Turning this on asks for \(DeviceAuthentication.unlockMethods).",
                           isOn: Binding(get: { access.config.allowAll }, set: { on in Task { await access.setAllowAll(on) } }))
                    .disabled(!access.config.enabled)
                SettingRow(symbol: "checkmark.shield.fill", color: .green, title: "Always Allowed", subtitle: rulesSummary,
                           info: "Apps that get codes without asking you. Unverified email always asks. To add an app, choose Always Allow on a request. Rules and Allow All give out at most 20 codes an hour in all. After that, CodeCatch asks again.") {
                    Button("Edit…") { showingRules = true }
                }
                SettingRow(symbol: "clock.arrow.circlepath", color: .teal, title: "Request History", subtitle: historySummary,
                           info: "Which app asked for which site, and what happened. Never the code. CodeCatch keeps the last 50.") {
                    Button("Show…") { showingHistory = true }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            tool = CommandLineTool.state
            skillsChanged()
        }
        .sheet(isPresented: $showingRules) { AgentRulesSheet() }
        .sheet(isPresented: $showingHistory) { AgentHistorySheet() }
    }

    /// Nil when there's nothing to say: on and installed, or off and not installed.
    private var toolSummary: String? {
        if let toolError { return toolError }
        switch (tool, access.config.enabled) {
        case (.installed, true), (.notInstalled, false), (.unavailable, false), (.taken, false): return nil
        case (.installed, false): return "Still installed. It does nothing while this is off."
        case (.unavailable(let why), true): return why
        case (.notInstalled, true): return "Not installed. Agents can still use the full path below."
        case (.stale, _): return "Points to a copy of CodeCatch that moved."
        case (.taken, true): return "Another program is named codecatch. Agents can use the full path below."
        }
    }

    /// On asks for Touch ID, then installs codecatch (an admin prompt where /usr/local/bin needs one).
    /// A cancelled install leaves access on: the row below offers Install, and the full path works.
    private func setEnabled(_ on: Bool) async {
        await access.setEnabled(on)
        tool = CommandLineTool.state
        guard on, access.config.enabled else { return }
        switch tool {
        case .notInstalled, .stale: change { try CommandLineTool.install(over: tool) }
        default: break
        }
    }

    private func skillsChanged() {
        skills = Dictionary(uniqueKeysWithValues: AgentSkill.allCases.map { ($0, $0.state(home: home)) })
    }

    private var rulesSummary: String {
        if access.config.allowAll { return "All agents, while Allow All is on" }
        let rules = access.config.rules
        guard let first = rules.first else { return "None" }
        let name = first.site ?? "All codes from \(first.app.name)"
        return rules.count == 1 ? name : "\(name) and \(rules.count - 1) more"
    }

    private var historySummary: String {
        guard let last = access.log.first else { return "None yet" }
        let when = last.date.formatted(.relative(presentation: .named))
        return last.site.isEmpty ? "\(last.outcome), \(when)" : "\(last.site): \(last.outcome), \(when)"
    }

    private func change(_ action: () throws -> Void) {
        do {
            try action()
            toolError = nil
        } catch is CancellationError {
        } catch {
            toolError = error.localizedDescription
        }
        tool = CommandLineTool.state
    }
}

/// An agent found on this Mac: Connect writes its skill, Disconnect removes it.
private struct AgentSkillRow: View {
    let agent: AgentSkill
    let state: AgentSkill.State
    let changed: () -> Void
    @Local private var error: String?

    var body: some View {
        HStack(spacing: 10) {
            SiteIcon(site: agent.domain)
            VStack(alignment: .leading, spacing: 1) {
                // The same dot as a source in Settings → Sources: green connected, gray not, orange in the way.
                HStack(spacing: 6) {
                    Text(agent.name)
                    Circle().fill(status.color).frame(width: 6, height: 6).accessibilityLabel(status == .live ? "Connected" : "Not connected")
                }
                .accessibilityElement(children: .combine)
                if let subtitle = error ?? subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .hoverInfo(agent.name, "Connect adds a codecatch skill to \(agent.name). It loads only when \(agent.name) needs a code, so it doesn’t add to every prompt.")
            Spacer(minLength: 12)
            switch state {
            case .notConnected: Button("Connect") { run { try agent.connect(home: home, guidance: CommandLineTool.guidance) } }
            case .connected: Button("Disconnect") { run { try agent.disconnect(home: home) } }
            case .connectedThrough, .taken: EmptyView()
            }
        }
    }

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    private var status: SourceStatus {
        switch state {
        case .notConnected: .off
        case .connected, .connectedThrough: .live
        case .taken: .attention("Not connected")
        }
    }

    /// Only what the dot can't say.
    private var subtitle: String? {
        switch state {
        case .notConnected, .connected: nil
        case .connectedThrough(let other): "Uses \(other.name)’s skill"
        case .taken: "Has a codecatch skill CodeCatch didn’t add"
        }
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        changed()
    }
}

/// A site's logo, a monogram when it has none, or a globe for every site.
private struct SiteIcon: View {
    let site: String?
    var size: CGFloat = 22
    @ObservedObject private var icons = IconStore.shared

    var body: some View {
        Group {
            if let site {
                if let icon = icons.icon(for: SiteQuery(site)?.domain) { LogoTile(icon: icon, size: size) } else { Monogram(name: site, size: size) }
            } else {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(Color.orange.gradient)
                    .frame(width: size, height: size)
                    .overlay(Image(systemName: "globe").font(.system(size: size * 0.55, weight: .semibold)).foregroundStyle(.white))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Settings → Agents → Always Allowed: every rule, laid out like Ignored Senders.
struct AgentRulesSheet: View {
    @ObservedObject private var access = AppModel.shared.agents
    @Environment(\.dismiss) private var dismiss
    @Local private var selection = Set<AgentRule.ID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Always Allowed").font(.title3.weight(.semibold))
                Text("These apps get codes without asking you. To add one, choose Always Allow on a request.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(rules) { AgentRuleRow(rule: $0) }
                }
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: AgentRule.ID.self) { picked in
                    Button("Stop Allowing") { remove(picked) }
                }
                .onDeleteCommand { remove(selection) }
                .overlay {
                    if rules.isEmpty {
                        ContentUnavailableView("Nothing Allowed", systemImage: "checkmark.shield",
                                               description: Text("Every code asks for \(DeviceAuthentication.unlockMethods)."))
                    }
                }
                Divider()
                HStack(spacing: 0) {
                    Button { remove(selection) } label: { Image(systemName: "minus").frame(width: 24, height: 22) }
                        .help("Stop allowing the selected")
                        .accessibilityLabel("Stop allowing")
                        .disabled(selection.isEmpty)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(4)
            }
            .frame(height: 280)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.04)))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    /// By app, then "all sites" before single sites, then by site.
    private var rules: [AgentRule] {
        access.config.rules.sorted { ($0.app.name, $0.site ?? "", $0.id.uuidString) < ($1.app.name, $1.site ?? "", $1.id.uuidString) }
    }

    private func remove(_ picked: Set<AgentRule.ID>) {
        guard !picked.isEmpty else { return }
        access.removeRules(picked)
        selection.subtract(picked)
    }
}

private struct AgentRuleRow: View {
    let rule: AgentRule

    var body: some View {
        HStack(spacing: 10) {
            SiteIcon(site: rule.site, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.site ?? "All Sites").lineLimit(1)
                Text("From \(rule.app.name)")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(rule.added.formatted(date: .abbreviated, time: .omitted)).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// Settings → Agents → Request History: recent requests by day, newest first, laid out like Ignored Senders.
struct AgentHistorySheet: View {
    @ObservedObject private var access = AppModel.shared.agents
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Request History").font(.title3.weight(.semibold))
                Text("What agents and scripts asked for, and what happened. Codes are never saved here.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                List {
                    // Day titles as plain rows: a List's section headers stick with an opaque background here.
                    ForEach(days, id: \.day) { group in
                        Text(title(group.day)).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.top, 6)
                            .listRowSeparator(.hidden)
                        ForEach(group.entries) { AgentLogRow(entry: $0) }
                    }
                }
                .scrollContentBackground(.hidden)
                .overlay {
                    if access.log.isEmpty {
                        ContentUnavailableView("No Requests", systemImage: "terminal",
                                               description: Text("Requests show here once an agent asks for a code."))
                    }
                }
                Divider()
                HStack {
                    Text(access.log.isEmpty ? "" : "Last \(access.log.count) of up to 50").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { access.clearLog() }.disabled(access.log.isEmpty)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .frame(height: 320)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.04)))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var days: [(day: Date, entries: [AgentLogEntry])] {
        Dictionary(grouping: access.log) { Calendar.current.startOfDay(for: $0.date) }
            .map { ($0.key, $0.value) }
            .sorted { $0.day > $1.day }
    }

    private func title(_ day: Date) -> String {
        Calendar.current.isDateInToday(day) ? "Today" : Calendar.current.isDateInYesterday(day) ? "Yesterday"
            : day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

private struct AgentLogRow: View {
    let entry: AgentLogEntry

    var body: some View {
        HStack(spacing: 10) {
            SiteIcon(site: entry.site.isEmpty ? nil : entry.site, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.site.isEmpty ? "CodeCatch" : entry.site).lineLimit(1)
                Text(entry.caller).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 5) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(entry.outcome).font(.subheadline)
                }
                Text(entry.date.formatted(date: .omitted, time: .shortened)).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    /// The same dots as a source's status: green went out, red was refused, orange ended another way.
    private var color: Color {
        entry.outcome.hasPrefix("Allowed") ? .green : entry.outcome == "Denied" ? .red : .orange
    }
}
