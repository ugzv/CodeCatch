import CodeCatchCore
import SwiftUI

/// Settings → Sources → Ignored Senders: a list with + and −, like Mail's blocked senders.
struct IgnoredSendersSheet: View {
    @ObservedObject private var model = AppModel.shared
    @Environment(\.dismiss) private var dismiss
    @Local private var selection = Set<String>()
    @Local private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ignored Senders").font(.title3.weight(.semibold))
                Text("CodeCatch skips codes and links from these senders. To ignore one, right-click its code in the menu, or click +.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(entries, id: \.self) { IgnoredSenderRow(entry: $0) }
                }
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: String.self) { picked in
                    Button("Stop Ignoring") { stopIgnoring(picked) }
                }
                .onDeleteCommand { stopIgnoring(selection) }
                .overlay {
                    if entries.isEmpty {
                        ContentUnavailableView("No Ignored Senders", systemImage: "nosign",
                                               description: Text("Ignore an email address, a whole domain, or a phone number."))
                    }
                }
                Divider()
                HStack(spacing: 0) {
                    Button { adding = true } label: { Image(systemName: "plus").frame(width: 24, height: 22) }
                        .help("Ignore a sender")
                        .accessibilityLabel("Ignore a sender")
                        .popover(isPresented: $adding, arrowEdge: .bottom) { AddIgnoredSender { selection = [$0] } }
                    Divider().frame(height: 14)
                    Button { stopIgnoring(selection) } label: { Image(systemName: "minus").frame(width: 24, height: 22) }
                        .help("Stop ignoring the selected senders")
                        .accessibilityLabel("Stop ignoring")
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

    /// By service, so a long list scans like the menu; then by entry, so an address and its domain sit together.
    private var entries: [String] {
        model.ignoredSenders.sorted { (IgnoredSender($0).name.lowercased(), $0) < (IgnoredSender($1).name.lowercased(), $1) }
    }

    private func stopIgnoring(_ picked: Set<String>) {
        guard !picked.isEmpty else { return }
        model.stopIgnoring(picked)
        selection.subtract(picked)
    }
}

/// What an entry covers, in words and with the service's logo.
private struct IgnoredSender {
    let entry: String
    init(_ entry: String) { self.entry = entry }

    private var isAddress: Bool { entry.contains("@") }
    private var isDomain: Bool { ServiceIdentity.isHostname(entry) }
    /// Addresses and domains go through the mail rules; "@acme.com" reads as any address there.
    private var address: String { isDomain ? "@" + entry : entry }

    var name: String { ServiceIdentity.name(senderName: "", senderAddress: address, isMail: isAddress || isDomain, text: "") }
    var domain: String? { ServiceIdentity.domain(senderAddress: address, isMail: isAddress || isDomain, text: "", service: entry) }
    var detail: String { isDomain ? "Every address at \(entry)" : isAddress ? entry : "Text messages" }
}

private struct IgnoredSenderRow: View {
    let entry: String
    @ObservedObject private var icons = IconStore.shared

    var body: some View {
        let sender = IgnoredSender(entry)
        HStack(spacing: 10) {
            Group {
                if let icon = icons.icon(for: sender.domain) { LogoTile(icon: icon, size: 28) } else { Monogram(name: sender.name, size: 28) }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(sender.name).lineLimit(1)
                Text(sender.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// The + popover: one field that takes an address, a domain or a phone number.
struct AddIgnoredSender: View {
    let added: (String) -> Void
    @ObservedObject private var model = AppModel.shared
    @Environment(\.dismiss) private var dismiss
    @Local private var text = ""
    @Local private var tried = false
    @FocusState private var focused: Bool

    private var entry: String? { ServiceIdentity.ignoreEntry(text) }
    private var alreadyIgnored: Bool { entry.map(model.isIgnored) ?? false }

    var body: some View {
        InfoCard(title: "Ignore a Sender") {
            TextField("Sender", text: $text, prompt: Text("Email, domain or phone number"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(add)
                .onChange(of: text) { tried = false }
            if alreadyIgnored {
                WarningText(message: "Already ignored.", calm: true)
            } else if tried, entry == nil {
                WarningText(message: text.contains("*") ? "A wildcard works only for a whole domain, like *@acme.com."
                                                        : "Enter an email address, a domain or a phone number.")
            } else {
                // Verbatim, so the examples don't turn into links.
                Text(verbatim: "For example security@acme.com, or acme.com for every address there. For texts, a number like +1 555 0100 or a sender name like Google.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Ignore", action: add).keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || alreadyIgnored)
            }
        }
        .onAppear { focused = true }
    }

    private func add() {
        tried = true
        guard let entry, !alreadyIgnored else { return }
        model.ignore(entry)
        added(entry)
        dismiss()
    }
}
