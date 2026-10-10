import Foundation

public struct MailMessage: Equatable, Sendable {
    public var fromName: String
    public var fromAddress: String
    public var subject: String
    public var text: String
    /// Every link, with its anchor (or surrounding line) text, for spotting sign-in links.
    public var links: [MailLink] = []
    /// The receiving server's verdict on the From domain; nil when it left none.
    public var senderVerified: Bool? = nil
    /// The Message-ID header without its angle brackets: what a `message://` link opens in Mail.
    public var messageID: String? = nil
}

public struct MailLink: Equatable, Sendable {
    public var url: String
    public var label: String

    public init(url: String, label: String) {
        self.url = url
        self.label = label
    }
}

/// Just enough RFC 5322/2045/2047 to turn a raw email into readable text:
/// multipart walking, base64 / quoted-printable, charsets, encoded-word headers, HTML to text.
public enum MIME {
    /// Only direct, authenticated receiver APIs establish this trust boundary. Never infer it from a message header.
    public enum Receiver: Sendable { case gmail, microsoft }

    public static func parse(_ raw: Data, receiver: Receiver? = nil) -> MailMessage {
        let (headers, body, results) = split(latin1(raw))
        let (name, address) = parseAddress(header(headers["from"]))
        let (text, links) = bodyText(headers: headers, body: body)
        let id = headers["message-id"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
        return MailMessage(fromName: name, fromAddress: address, subject: header(headers["subject"]), text: text, links: links,
                           senderVerified: senderVerified(results, receiver: receiver, fromAddress: address), messageID: id?.isEmpty == false ? id : nil)
    }

    /// Receiver identity comes from the authenticated API, never from the message. Receivers must
    /// remove forged results claiming their identity (RFC 8601 section 7.1). Only their first header
    /// counts; combining later headers lets an attacker override a genuine failure.
    static func senderVerified(_ results: [String], receiver: Receiver?, fromAddress: String) -> Bool? {
        guard let receiver, let top = results.first, let parts = authenticationParts(top), let first = parts.first else { return nil }
        switch receiver {
        case .gmail:
            guard first.lowercased() == "mx.google.com" else { return nil }
        case .microsoft:
            guard first.range(of: #"^(spf|dkim|dmarc|compauth)\s*="#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        }
        let verdicts = parts.filter { $0.range(of: #"^dmarc(?:\s|=|$)"#, options: [.regularExpression, .caseInsensitive]) != nil }
        guard verdicts.count == 1, let verdict = verdicts.first,
              let result = verdict.range(of: #"^dmarc\s*=\s*(pass|fail)(?=\s|$)"#, options: [.regularExpression, .caseInsensitive]),
              let domain = fromAddress.split(separator: "@", omittingEmptySubsequences: false).last,
              fromAddress.filter({ $0 == "@" }).count == 1 else { return nil }
        let property = try! NSRegularExpression(pattern: #"(?:^|\s)header\.from\s*=\s*(?:"([^"]+)"|([^\s]+))(?=\s|$)"#, options: .caseInsensitive)
        let ns = verdict as NSString
        let matches = property.matches(in: verdict, range: NSRange(location: 0, length: ns.length))
        guard matches.count == 1, let match = matches.first else { return nil }
        let value = ns.substring(with: match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1))
        guard !domain.isEmpty, value.lowercased() == domain.lowercased() else { return nil }
        return verdict[result].lowercased().trimmingCharacters(in: .whitespaces).hasSuffix("pass")
    }

    /// Split method results without treating quoted or commented semicolons as new methods.
    private static func authenticationParts(_ value: String) -> [String]? {
        var parts: [String] = [], part = "", comments = 0, quoted = false, escaped = false
        for c in value {
            if escaped {
                if comments == 0 { part.append(c) }
                escaped = false
            } else if c == "\\", quoted || comments > 0 {
                if comments == 0 { part.append(c) }
                escaped = true
            } else if comments > 0 {
                if c == "(" { comments += 1 }
                if c == ")" { comments -= 1 }
            } else if c == "\"" {
                quoted.toggle(); part.append(c)
            } else if !quoted, c == "(" {
                comments = 1; part.append(" ")
            } else if !quoted, c == ";" {
                parts.append(part.trimmingCharacters(in: .whitespacesAndNewlines)); part = ""
            } else {
                part.append(c)
            }
        }
        guard !quoted, comments == 0, !escaped else { return nil }
        parts.append(part.trimmingCharacters(in: .whitespacesAndNewlines))
        return parts
    }

    /// Encoded words, or raw UTF-8 (RFC 6532), which the Latin-1 read left as mojibake.
    private static func header(_ value: String?) -> String {
        let bytes = Data((value ?? "").unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
        return decodeWords(String(data: bytes, encoding: .utf8) ?? value ?? "")
    }

    // MARK: - Structure

    /// Bytes as ISO-8859-1: a lossless 1:1 byte mapping, so parts can be re-encoded
    /// to their bytes and decoded with their own charset later.
    private static func latin1(_ data: Data) -> String { String(decoding: data.map { UInt16($0) }, as: UTF16.self) }

    /// Headers (the first of each name), the body, and every Authentication-Results in order.
    private static func split(_ s: String) -> ([String: String], String, [String]) {
        let s = s.replacingOccurrences(of: "\r\n", with: "\n")
        if s.hasPrefix("\n") { return ([:], String(s.dropFirst()), []) }  // no headers at all
        let parts = s.components(separatedBy: "\n\n")
        let body = parts.dropFirst().joined(separator: "\n\n")
        var headers: [String: String] = [:]
        var results: [String] = []
        var current: (String, String)?
        func flush() {
            guard let c = current else { return }
            if headers[c.0] == nil { headers[c.0] = c.1 }
            if c.0 == "authentication-results" { results.append(c.1) }
        }
        for line in parts[0].split(separator: "\n", omittingEmptySubsequences: false) {
            if line.first == " " || line.first == "\t", current != nil {
                current!.1 += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            flush()
            guard let colon = line.firstIndex(of: ":") else { current = nil; continue }
            current = (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        flush()
        return (headers, body, results)
    }

    private static func bodyText(headers: [String: String], body: String) -> (String, [MailLink]) {
        var plain: String?, html: String?
        collect(headers: headers, body: body, plain: &plain, html: &html, depth: 0)
        let parsedHTML = html.map(readHTML)
        let links = parsedHTML?.links ?? plain.map(bareLinks) ?? []
        if let plain, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (plain, links) }
        return (parsedHTML?.text ?? "", links)
    }

    private static let bareURL = try! NSRegularExpression(pattern: #"https?://[^\s<>"'\])]+"#)

    /// `<a href>` with its visible text (or an image button's alt text).
    static func anchors(_ html: String) -> [MailLink] { readHTML(html).links }

    /// Plain-text mail: each URL labelled by the rest of its line, or, alone on its line,
    /// by the text line above it ("Sign in here:" then the URL).
    static func bareLinks(_ text: String) -> [MailLink] {
        let trim = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        var above: String?
        return text.split(separator: "\n").flatMap { line -> [MailLink] in
            let l = String(line), ns = l as NSString
            let matches = bareURL.matches(in: l, range: NSRange(location: 0, length: ns.length))
            defer {
                let text = l.trimmingCharacters(in: trim)
                if !matches.isEmpty { above = nil } else if !text.isEmpty { above = text }
            }
            return matches.map { m in
                let url = ns.substring(with: m.range).replacingOccurrences(of: #"[.,;:!?]+$"#, with: "", options: .regularExpression)
                let label = l.replacingOccurrences(of: url, with: "").trimmingCharacters(in: trim)
                return MailLink(url: url, label: label.isEmpty && matches.count == 1 ? above ?? "" : label)
            }
        }
    }

    private static func collect(headers: [String: String], body: String, plain: inout String?, html: inout String?, depth: Int) {
        let (type, params) = contentType(headers["content-type"] ?? "text/plain")
        if type.hasPrefix("multipart/"), let boundary = params["boundary"], depth < 8 {
            for chunk in body.components(separatedBy: "--" + boundary).dropFirst() {
                if chunk.hasPrefix("--") { break }
                let (h, b, _) = split(String(chunk.drop(while: { $0 != "\n" }).dropFirst()))  // rest of the boundary line
                collect(headers: h, body: b, plain: &plain, html: &html, depth: depth + 1)
            }
            return
        }
        guard type == "text/plain" || type == "text/html",
              !(headers["content-disposition"] ?? "").lowercased().hasPrefix("attachment") else { return }
        let bytes = decodeTransfer(body, encoding: (headers["content-transfer-encoding"] ?? "").lowercased())
        let text = decodeCharset(bytes, params["charset"])
        if type == "text/plain" { plain = plain ?? text } else { html = html ?? text }
    }

    private static func contentType(_ value: String) -> (String, [String: String]) {
        let parts = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        var params: [String: String] = [:]
        for p in parts.dropFirst() {
            guard let eq = p.firstIndex(of: "=") else { continue }
            params[p[..<eq].lowercased()] = p[p.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }
        return (parts.first?.lowercased() ?? "text/plain", params)
    }

    // MARK: - Decoding

    private static func decodeTransfer(_ body: String, encoding: String) -> Data {
        let bytes = Data(body.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
        switch encoding {
        case "base64":
            // Whole groups only: a part cut at the read limit would otherwise not decode at all.
            let b64 = body.filter { !$0.isWhitespace }
            return Data(base64Encoded: String(b64.prefix(b64.count / 4 * 4)), options: .ignoreUnknownCharacters) ?? bytes
        case "quoted-printable":
            return quotedPrintable(bytes, underscoreIsSpace: false)
        default:
            return bytes
        }
    }

    private static func quotedPrintable(_ bytes: Data, underscoreIsSpace: Bool) -> Data {
        let b = [UInt8](bytes)
        var out = Data(), i = 0
        while i < b.count {
            if b[i] == UInt8(ascii: "="), i + 1 < b.count, b[i + 1] == 0x0A { i += 2; continue }
            if b[i] == UInt8(ascii: "="), i + 2 < b.count, b[i + 1] == 0x0D, b[i + 2] == 0x0A { i += 3; continue }
            if b[i] == UInt8(ascii: "="), i + 2 < b.count, let v = UInt8(String(bytes: b[i + 1...i + 2], encoding: .ascii) ?? "", radix: 16) {
                out.append(v); i += 3; continue
            }
            out.append(underscoreIsSpace && b[i] == UInt8(ascii: "_") ? 0x20 : b[i])
            i += 1
        }
        return out
    }

    private static func decodeCharset(_ data: Data, _ charset: String?) -> String {
        if let charset {
            let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cf != kCFStringEncodingInvalidId,
               let s = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) {
                return s
            }
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data.map { UInt16($0) }, as: UTF16.self)
    }

    private static let encodedWord = try! NSRegularExpression(pattern: #"=\?([^?]+)\?([BbQq])\?([^?]*)\?="#)

    /// RFC 2047 `=?charset?B|Q?...?=` words; whitespace between adjacent words is dropped.
    static func decodeWords(_ value: String) -> String {
        let v = value.replacingOccurrences(of: #"\?=\s+=\?"#, with: "?==?", options: .regularExpression)
        let ns = v as NSString
        var out = "", last = 0
        for m in encodedWord.matches(in: v, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let payload = ns.substring(with: m.range(at: 3))
            let data = ns.substring(with: m.range(at: 2)).uppercased() == "B"
                ? Data(base64Encoded: payload, options: .ignoreUnknownCharacters) ?? Data()
                : quotedPrintable(Data(payload.utf8), underscoreIsSpace: true)
            out += decodeCharset(data, ns.substring(with: m.range(at: 1)))
            last = m.range.upperBound
        }
        return out + ns.substring(from: last)
    }

    private static func parseAddress(_ from: String) -> (String, String) {
        guard let lt = from.lastIndex(of: "<"), let gt = from.lastIndex(of: ">"), lt < gt else {
            return ("", from.trimmingCharacters(in: .whitespaces))
        }
        let name = from[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: "\" ").union(.whitespaces))
        return (name, String(from[from.index(after: lt)..<gt]))
    }

    // MARK: - HTML

    /// "&amp;" last, so "&amp;lt;" stays the text "&lt;".
    private static let entities = [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&zwnj;", ""), ("&shy;", ""), ("&amp;", "&")]

    /// A forward-only scan keeps malformed markup from repeatedly searching the remaining message.
    /// This extracts text and links; it does not render or execute HTML.
    private static func readHTML(_ html: String) -> (text: String, links: [MailLink]) {
        let bytes = Array(html.utf8)
        var i = 0, text = "", links: [MailLink] = [], hidden: [UInt8]?
        var anchor: (url: String, text: String, alt: String?)?
        func append(_ value: String) { text += value; anchor?.text += value }
        func string(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
        let commentStart: [UInt8] = [60, 33, 45, 45], commentEnd: [UInt8] = [45, 45, 62]
        func matches(_ expected: [UInt8], at offset: Int) -> Bool {
            guard offset + expected.count <= bytes.count else { return false }
            return expected.enumerated().allSatisfy { j, b in
                let actual = bytes[offset + j]
                return (actual >= 65 && actual <= 90 ? actual + 32 : actual) == b
            }
        }
        while i < bytes.count {
            if let close = hidden {
                if !matches(close, at: i) { i += 1; continue }
                let end = i + close.count
                guard end < bytes.count, htmlSpace(bytes[end]) || bytes[end] == 62 else { i += 1; continue }
            }
            if bytes[i] != 60 {
                let start = i
                while i < bytes.count, bytes[i] != 60 { i += 1 }
                append(string(start..<i)); continue
            }
            if matches(commentStart, at: i) {
                i += 4
                while i < bytes.count, !matches(commentEnd, at: i) { i += 1 }
                i = min(i + 3, bytes.count); continue
            }
            let start = i + 1
            var end = start, quote: UInt8?
            while end < bytes.count {
                let c = bytes[end]
                if let q = quote { if c == q { quote = nil } }
                else if c == 34 || c == 39 { quote = c }
                else if c == 62 { break }
                end += 1
            }
            guard end < bytes.count else { break }
            i = end + 1
            var cursor = start
            while cursor < end, htmlSpace(bytes[cursor]) { cursor += 1 }
            let closing = cursor < end && bytes[cursor] == 47
            if closing { cursor += 1 }
            let nameStart = cursor
            while cursor < end, !htmlSpace(bytes[cursor]), bytes[cursor] != 47 { cursor += 1 }
            let name = string(nameStart..<cursor).lowercased()
            if hidden != nil { hidden = nil; append(" "); continue }
            if !closing, ["style", "script", "title"].contains(name) {
                hidden = Array(("</" + name).utf8); append(" "); continue
            }
            if name == "br" || closing && ["p", "div", "tr", "td", "th", "h1", "h2", "h3", "h4", "h5", "h6", "li", "table", "center"].contains(name) {
                append("\n")
            } else { append(" ") }
            if name == "a", closing {
                if let current = anchor {
                    let label = readableHTMLText(current.text).replacingOccurrences(of: "\n", with: " ")
                    links.append(MailLink(url: current.url, label: label.isEmpty ? decodeEntities(current.alt ?? "") : label))
                }
                anchor = nil
            } else if !closing, name == "a" || name == "img" {
                let attributes = htmlAttributes(bytes, start: cursor, end: end)
                if name == "a" {
                    anchor = attributes["href"].map {
                        (decodeEntities($0).filter { $0 != "\t" && $0 != "\r" && $0 != "\n" }, "", nil)
                    }
                } else if anchor?.alt == nil { anchor?.alt = attributes["alt"] }
            }
        }
        return (readableHTMLText(text), links)
    }

    private static func htmlSpace(_ byte: UInt8) -> Bool { byte == 32 || (byte >= 9 && byte <= 13) }

    /// Only href and alt are needed. Consume each attribute once, including unquoted values.
    private static func htmlAttributes(_ bytes: [UInt8], start: Int, end: Int) -> [String: String] {
        var result: [String: String] = [:], i = start
        while i < end {
            while i < end, htmlSpace(bytes[i]) || bytes[i] == 47 { i += 1 }
            let start = i
            while i < end, !htmlSpace(bytes[i]), bytes[i] != 61, bytes[i] != 47 { i += 1 }
            let name = String(decoding: bytes[start..<i], as: UTF8.self).lowercased()
            while i < end, htmlSpace(bytes[i]) { i += 1 }
            guard i < end, bytes[i] == 61 else { continue }
            i += 1
            while i < end, htmlSpace(bytes[i]) { i += 1 }
            let quote = i < end && (bytes[i] == 34 || bytes[i] == 39) ? bytes[i] : nil
            if quote != nil { i += 1 }
            let valueStart = i
            while i < end {
                if let quote { if bytes[i] == quote { break } }
                else if htmlSpace(bytes[i]) { break }
                i += 1
            }
            if (name == "href" || name == "alt"), result[name] == nil {
                result[name] = String(decoding: bytes[valueStart..<i], as: UTF8.self)
            }
            if quote != nil, i < end { i += 1 }
        }
        return result
    }

    static func htmlToText(_ html: String) -> String { readHTML(html).text }

    private static func readableHTMLText(_ text: String) -> String {
        decodeEntities(text).split(separator: "\n")
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Numeric entities before "&amp;", so "&amp;#61;" stays the text "&#61;".
    private static func decodeEntities(_ s: String) -> String {
        var s = s
        for (entity, char) in entities.dropLast() { s = s.replacingOccurrences(of: entity, with: char, options: .caseInsensitive) }
        return decodeNumericEntities(s).replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
    }

    private static func decodeNumericEntities(_ s: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#)
        let ns = s as NSString
        var out = "", last = 0
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let hex = m.range(at: 1).length > 0
            if let v = UInt32(ns.substring(with: m.range(at: 2)), radix: hex ? 16 : 10), let scalar = Unicode.Scalar(v) {
                out.unicodeScalars.append(scalar)
            }
            last = m.range.upperBound
        }
        return out + ns.substring(from: last)
    }
}
