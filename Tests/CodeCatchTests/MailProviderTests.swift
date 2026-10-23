import Foundation
import Testing

@testable import CodeCatch

/// The addresses and servers the Add Account sheet and the address guess know about.
struct MailProviderTests {
    @Test(
        arguments: [
            ("you@163.com", "imap.163.com", "163"),
            ("you@126.com", "imap.126.com", "126"),
            ("you@gmail.com", "imap.gmail.com", "Gmail"),
            ("you@googlemail.com", "imap.gmail.com", "Gmail"),
            ("you@outlook.com", "outlook.office365.com", "Outlook"),
            ("you@hotmail.com", "outlook.office365.com", "Outlook"),
            ("you@example.com", "imap.example.com", "Example"),
            ("you@mail.example.invalid", "imap.mail.example.invalid", "Mail"),
        ])
    func guessesTheServerFromTheAddress(address: String, host: String, label: String) {
        let guess = MailAccount.guess(for: address)
        #expect(guess.host == host)
        #expect(guess.label == label)
        #expect(guess.user == address)
        #expect(guess.port == 993)
    }

    @Test(
        arguments: [
            ("imap.163.com", true), ("imap.126.com", true), ("IMAP.163.COM", true),
            ("imap.gmail.com", false), ("outlook.office365.com", false), ("imap.example.com", false),
        ])
    func recognizesNetEaseServers(_ host: String, _ expected: Bool) {
        #expect(MailAccount(label: "Mail", host: host, user: "you@example.com").isNetEase == expected)
    }

    /// NetEase's two mailboxes get their own row, so the editor opens with the server filled in.
    @Test func addAccountSheetOffersBothNetEaseMailboxes() {
        let netEase = AddAccountSheet.others.filter { $0.host == MailAccount.netEase163Host || $0.host == MailAccount.netEase126Host }
        #expect(netEase.map(\.name) == ["163 Mail", "126 Mail"])
        #expect(netEase.map(\.label) == ["163", "126"])
        #expect(netEase.map(\.host) == [MailAccount.netEase163Host, MailAccount.netEase126Host])
        for provider in netEase {
            #expect(provider.detail.contains("authorization code"))
            let account = MailAccount(label: provider.label, host: provider.host, user: "")
            #expect(account.isNetEase)
            #expect(account.port == 993)
            #expect(account.provider == nil)
        }
    }

    /// The sheet's other choices are unchanged: custom domains and the other providers keep their rows.
    @Test func otherProviderChoicesAreUnchanged() {
        #expect(AddAccountSheet.others.map(\.name) == ["163 Mail", "126 Mail", "iCloud Mail", "Yahoo Mail", "Other IMAP Account"])
        #expect(AddAccountSheet.others.last?.host == "")
    }

    @Test func netEaseHelpIsTheOfficialHTTPSPage() throws {
        let help = MailAccount.netEaseHelp
        #expect(help.scheme == "https")
        #expect(try #require(help.host).hasSuffix("mail.163.com"))
    }
}
