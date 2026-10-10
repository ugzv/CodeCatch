import AppKit
import SwiftUI

struct MenuContent: View {
    @ObservedObject private var model = AppModel.shared
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Local private var query = ""
    @Local private var selectedID: UUID?
    /// Measured, for sizing the popover window to it (see TopAnchor).
    @Local private var contentHeight: CGFloat = 0
    @FocusState private var searchFocused: Bool
    @Namespace private var selectionSpace
    /// Opened for searching (shortcut or codecatch:// link): show the field even for a short list.
    @Local private var searchRequested = false
    /// At rest the list is the newest few codes; the rest of the history is one click away.
    @Local private var showOlder = false
    private static let recent = 5

    private var hasLogins: Bool { model.monitoring(Prefs.bitwarden) && model.hasVault }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Search mixes all sources; at rest, only pinned or recently used logins join the inbox.
    private var results: (latest: CodeItem?, shortcuts: [CodeItem], rest: [CodeItem]) {
        if searching {
            return (nil, [], model.search.ranked(model.items + model.vaultItems, query: query, now: model.now, secrets: model.isUnlocked))
        }
        let latest = model.latest
        let rest = model.items.filter { $0.id != latest?.id }
        return (latest, model.search.shortcuts(from: model.vaultItems), showOlder ? rest : Array(rest.prefix(Self.recent)))
    }

    private var orderedResults: [CodeItem] {
        let (latest, shortcuts, rest) = results
        return [latest].compactMap { $0 } + shortcuts + rest
    }

    private var selection: CodeItem? {
        let items = orderedResults
        return items.first { $0.id == selectedID } ?? items.first
    }

    /// ⌘⌫ clears the selected code, or the top one when none is selected. While a query
    /// is typed the keys stay with the search field.
    private var clearable: CodeItem? {
        guard !searching, model.isUnlocked, let item = selection, item.origin != .vault else { return nil }
        return item
    }

    var body: some View {
        let (latest, shortcuts, rest) = results
        let items = [latest].compactMap { $0 } + shortcuts + rest
        let selectionID = searchFocused ? (items.first { $0.id == selectedID } ?? items.first)?.id : nil
        VStack(spacing: 0) {
            header
            // Silent while everything works; a source that needs you gets a banner.
            if let problem = model.sources.first(where: \.status.needsAttention) {
                attention(problem.label, problem.status).padding(.horizontal, 10).padding(.bottom, 10)
            } else if model.receiving, !hasLogins, model.sources.allSatisfy({ $0.status == .off }) {
                attention("All sources off", .attention("Turn on a source in Settings."))
                    .padding(.horizontal, 10).padding(.bottom, 10)
            }
            if model.items.count > Self.recent || hasLogins || searchRequested { searchField }
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(spacing: 0) {
                        if let latest {
                            CodeCard(item: latest, style: .menu)
                                .id(latest.id)
                                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.primary.opacity(0.04)))
                                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
                                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.accentColor.opacity(selectionID == latest.id ? 0.7 : 0), lineWidth: 2))
                                .padding(.horizontal, 10)
                                .contextMenu { CodeMenu(item: latest) }
                        }
                        if model.items.isEmpty, shortcuts.isEmpty, !searching {
                            emptyState
                        } else if rest.isEmpty, searching {
                            // Saved logins are only loaded once unlocked: say so rather than "no match".
                            Text(hasLogins && !model.isUnlocked ? "Unlock to search your Bitwarden logins." : "No codes match “\(query)”")
                                .font(.callout).foregroundStyle(.secondary)
                                .padding(.vertical, 24)
                        } else if !rest.isEmpty || !shortcuts.isEmpty {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                if !shortcuts.isEmpty {
                                    Section {
                                        ForEach(shortcuts) { CodeRow(item: $0, selected: selectionID == $0.id, selection: selectionSpace).id($0.id) }
                                    } header: {
                                        sectionTitle("Your Logins", count: shortcuts.count)
                                    }
                                }
                                if searching {
                                    ForEach(rest) { CodeRow(item: $0, selected: selectionID == $0.id, selection: selectionSpace).id($0.id) }
                                } else {
                                    ForEach(days(rest), id: \.title) { day in
                                        Section {
                                            ForEach(day.items) { CodeRow(item: $0, selected: selectionID == $0.id, selection: selectionSpace).id($0.id) }
                                        } header: {
                                            sectionTitle(day.title, count: day.items.count, noun: day.items.contains(where: \.isLink) ? "item" : "code")
                                        }
                                    }
                                    if !showOlder, model.items.count - (latest == nil ? 0 : 1) > Self.recent {
                                        Button("Show \(model.items.count - (latest == nil ? 0 : 1) - Self.recent) Older") { showOlder = true }
                                            .buttonStyle(.plain).font(.subheadline).foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                                    }
                                }
                            }
                            .padding(.horizontal, 6)
                            .animation(.snappy(duration: 0.18), value: selectionID)
                        }
                    }
                }
                .onChange(of: selectionID) { _, id in
                    if let id { scroll.scrollTo(id) }
                }
            }
            .frame(maxHeight: 540)
            .fixedSize(horizontal: false, vertical: true)
            footer
        }
        .frame(width: 420)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        .background(TopAnchor(height: contentHeight))
        .hiddenFromCapture()
        .onChange(of: query) { selectedID = nil }
        .onChange(of: items.map(\.id)) { _, ids in
            if let selectedID, !ids.contains(selectedID) { self.selectedID = nil }
        }
        .onReceive(model.$searchRequest) { request in
            guard let request else { return }
            model.searchRequest = nil
            query = request
            searchRequested = true
            DispatchQueue.main.async { searchFocused = true }  // once the popover is key
        }
    }

    /// Return in the search field: the selected result's primary action, as on its card (Return is
    /// the card's Open Link shortcut): copy a code, open a sign-in link. Then step back to
    /// the app you came from, ready for ⌘V.
    private func submit() {
        guard let item = selection else { return NSSound.beep() }
        model.unlocked {
            query = ""
            if item.isLink { return model.open(item, leavingMenu: true) }
            model.copy(item)
            NSApp.hide(nil)
        }
    }

    private func moveSelection(_ offset: Int) -> KeyPress.Result {
        let items = orderedResults
        guard searchFocused, !items.isEmpty else { return .ignored }
        let index = items.firstIndex { $0.id == selectedID } ?? 0
        selectedID = items[min(max(index + offset, 0), items.count - 1)].id
        return .handled
    }

    /// Today / Yesterday / "Monday 27 Sep", newest first.
    private func days(_ items: [CodeItem]) -> [(title: String, items: [CodeItem])] {
        let calendar = Calendar.current
        var out: [(title: String, items: [CodeItem])] = []
        for item in items {
            let title = calendar.isDateInToday(item.received) ? "Today"
                : calendar.isDateInYesterday(item.received) ? "Yesterday"
                : item.received.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
            if out.last?.title == title { out[out.count - 1].items.append(item) } else { out.append((title, [item])) }
        }
        return out
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $query).textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit(submit)
                .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { key in
                    guard key.modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return .ignored }
                    return moveSelection(key.key == .downArrow ? 1 : -1)
                }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.primary.opacity(0.06)))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var header: some View {
        HStack {
            BrandHeading()
            Spacer()
            if let version = AppBrand.version {
                Text("v\(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Version \(version)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 13)
        .padding(.bottom, 11)
    }

    /// Bottom left, in both states: Unlock while codes are hidden, the open padlock to hide them again.
    @ViewBuilder private var lockControl: some View {
        if model.vaultSession.isUnlocked {
            GlyphButton(symbol: "lock.open", help: "Lock: hide codes until you unlock again") { model.vaultSession.lock() }
        } else {
            // Unlocking here also copies the newest code, as a fresh one would be.
            VaultUnlockButton(isBusy: model.vaultSession.isBusy) { Task { try? await model.unlock() } }
                .controlSize(.small)
                .help("Codes are hidden until you unlock")
            if let error = model.unlockError { WarningText(message: error, compact: true).font(.caption) }
        }
    }

    private func attention(_ label: String, _ status: SourceStatus) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.callout.weight(.semibold))
                Text(status.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 6)
            Button("Fix…") {
                if status == .attention(SourceStatus.needsDiskAccess) { return SystemSettings.fullDiskAccess() }
                openSettings(at: .sources)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.1)))
    }

    private func sectionTitle(_ title: String, count: Int, noun: String = "code") -> some View {
        HStack {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Text(count == 1 ? "1 \(noun)" : "\(count) \(noun)s").font(.subheadline).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    /// Codes aren't stored: after a launch they are read again, and until then "no codes" isn't true.
    private var checking: Bool { model.receiving && model.status.values.contains(.connecting) }

    @ViewBuilder private var emptyState: some View {
        if checking {
            ProgressView("Checking your inboxes…")
                .controlSize(.small).font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 56)
        } else {
            emptyNotice
        }
    }

    private var emptyNotice: some View {
        ContentUnavailableView {
            Label(!model.receiving && model.vault.isEmpty ? "Catching Paused" : model.vault.isEmpty ? "No Codes Yet" : "Find a Saved Login", systemImage: "key.viewfinder")
        } description: {
            Text(!model.receiving && model.vault.isEmpty
                 ? (hasLogins ? "Unlock to search your saved Bitwarden logins." : "Choose what to catch in Settings → Sources.")
                 : model.vault.isEmpty
                 ? "New codes and links show up here as they arrive."
                 : "Search by service or account. Pin a login to keep it here.")
        }
        .padding(.bottom, 8)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            lockControl
            Spacer()
            // Recent Emails reads only mail: with Messages alone it would be an empty window.
            if model.monitoring(Prefs.receivedCodes), !model.mailSourceKeys.isEmpty {
                Button("Can’t find your code?") {
                    NSApp.activate()
                    openWindow(id: "recovery")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
            }
            GlyphButton(symbol: "gearshape", help: "Settings") { openSettings(at: nil) }
            Menu {
                Button("Show Test Code") { model.showTestCode() }
                    .disabled(!model.monitoring(Prefs.receivedCodes))
                Button("Clear Code") { clearable.map(model.dismiss) }
                    .keyboardShortcut(.delete)
                    .disabled(clearable == nil)
                Button("Clear History…") { confirmClearHistory(model) }
                    .disabled(!model.hasHistory)
                Divider()
                Button("Settings…") { openSettings(at: nil) }.keyboardShortcut(",")
                Button("Welcome Guide") {
                    NSApp.activate()
                    openWindow(id: WelcomeView.windowID)
                }
                Button("About CodeCatch", action: AppBrand.showAbout)
                Divider()
                Button("Report a Bug…") { AppBrand.openIssue(.bug) }
                Button("Suggest a Feature…") { AppBrand.openIssue(.feature) }
                Divider()
                Button("Check for Updates…") {
                    NSApp.activate()
                    Updater.controller?.checkForUpdates(nil)
                }
                .disabled(Updater.controller == nil)
                Button("Quit CodeCatch") { NSApp.terminate(nil) }
            } label: {
                GlyphLabel(symbol: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24, height: 24)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Divider().padding(.horizontal, 12) }
        .padding(.top, 8)
    }
}
