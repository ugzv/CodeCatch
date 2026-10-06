import CodeCatchCore
import Foundation

/// A message from any source, before code extraction.
struct IncomingMessage {
    var text: String
    var subject: String? = nil
    var senderName: String
    var senderID: String
    var sourceKey: String
    var sourceLabel: String
    var date: Date
    var isMail: Bool
    var links: [MailLink] = []
    /// Source identifier only; never a code or a sign-in token.
    var messageID: String? = nil
    /// The mail server's verdict on the From domain; nil when it left none.
    var senderVerified: Bool? = nil

    /// Subject and body: what codes and service names are read from.
    var fullText: String { [subject, text].compactMap { $0 }.joined(separator: "\n") }
    var dismissKey: String { "message:\(sourceKey)|\(messageID ?? "\(senderID.lowercased())|\(date.timeIntervalSince1970)")" }
    var service: String { ServiceIdentity.name(senderName: senderName, senderAddress: senderID, isMail: isMail, text: fullText) }
}
