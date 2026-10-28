import AppKit
import SwiftUI

/// Each provider opens the same editor, with its server filled in.
struct AddAccountSheet: View {
    let edit: (MailAccount) -> Void
    @ObservedObject private var icons = IconStore.shared
    @Environment(\.dismiss) private var dismiss

    struct Provider {
        let name: String, label: String, detail: String, host: String, symbol: String, color: Color
    }

    /// The servers offered below Microsoft. Each fills in its host, so the editor asks for the
    /// address and credential only. NetEase is listed where its addresses are, as 163 and 126
    /// share a platform but not a host name.
    static let others = [
        Provider(
            name: "163 Mail", label: "163", detail: "NetEase · with a client authorization code, not your password",
            host: MailAccount.netEase163Host, symbol: "envelope.fill", color: .red),
        Provider(
            name: "126 Mail", label: "126", detail: "NetEase · with a client authorization code, not your password",
            host: MailAccount.netEase126Host, symbol: "envelope.fill", color: .red),
        Provider(
            name: "iCloud Mail", label: "iCloud", detail: "With an app-specific password from account.apple.com",
            host: "imap.mail.me.com", symbol: "icloud.fill", color: .blue),
        Provider(
            name: "Yahoo Mail", label: "Yahoo", detail: "With an app password from Yahoo account security",
            host: "imap.mail.yahoo.com", symbol: "y.circle.fill", color: .purple),
        Provider(
            name: "Other IMAP Account", label: "", detail: "Any server, with a password",
            host: "", symbol: "envelope.fill", color: .gray),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: "Add a Mail Account", about: "CodeCatch watches the inbox for codes and sign-in links. Your mail stays on the server.")
            VStack(spacing: 0) {
                row(
                    icon: AnyView(logo("google.com", fallback: "g.circle.fill", color: .red)), name: "Google",
                    detail: "Gmail · Sign in with Google (beta) or an app password"
                ) {
                    dismiss()
                    edit(MailAccount(label: "Gmail", host: MailAccount.gmailHost, user: ""))
                }
                Divider().padding(.leading, 52)
                row(
                    icon: AnyView(logo("microsoft.com", fallback: "m.circle.fill", color: .blue)), name: "Microsoft",
                    detail: "Outlook and Hotmail · Sign in with Microsoft (beta)"
                ) {
                    dismiss()
                    edit(MailAccount(label: "Outlook", host: MailAccount.outlookHost, user: ""))
                }
                ForEach(Self.others, id: \.name) { provider in
                    Divider().padding(.leading, 52)
                    row(
                        icon: AnyView(IconTile(symbol: provider.symbol, color: provider.color).scaleEffect(1.3)),
                        name: provider.name, detail: provider.detail
                    ) {
                        dismiss()
                        edit(MailAccount(label: provider.label, host: provider.host, user: ""))
                    }
                }
            }
            .well()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func logo(_ domain: String, fallback: String, color: Color) -> some View {
        Group {
            if let logo = icons.icon(for: domain) {
                Image(nsImage: logo.image).resizable().interpolation(.high).scaledToFit().padding(4)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white))
            } else {
                IconTile(symbol: fallback, color: color).scaleEffect(1.3)
            }
        }
        .frame(width: 28, height: 28)
    }

    private func row(icon: AnyView, name: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                icon.frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.body.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .hoverHighlight(in: Rectangle())
        }
        .buttonStyle(.plain)
    }

}
