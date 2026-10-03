import Foundation

public struct MailMessage: Equatable, Sendable {
    public var fromName: String
    public var fromAddress: String
    public var subject: String
    public var text: String
    /// Every link, with its anchor (or surrounding line) text, for spotting sign-in links.
    public var links: [MailLink] = []
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
    public static func parse(_ raw: Data) -> MailMessage {
        let (headers, body) = split(latin1(raw))
        let (name, address) = parseAddress(header(headers["from"]))
        let (text, links) = bodyText(headers: headers, body: body)
        return MailMessage(fromName: name, fromAddress: address, subject: header(headers["subject"]), text: text, links: links)
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

    private static func split(_ s: String) -> ([String: String], String) {
        let s = s.replacingOccurrences(of: "\r\n", with: "\n")
        if s.hasPrefix("\n") { return ([:], String(s.dropFirst())) }  // no headers at all
        let parts = s.components(separatedBy: "\n\n")
        let body = parts.dropFirst().joined(separator: "\n\n")
        var headers: [String: String] = [:]
        var current: (String, String)?
        for line in parts[0].split(separator: "\n", omittingEmptySubsequences: false) {
            if line.first == " " || line.first == "\t", current != nil {
                current!.1 += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            if let c = current, headers[c.0] == nil { headers[c.0] = c.1 }
            guard let colon = line.firstIndex(of: ":") else { current = nil; continue }
            current = (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        if let c = current, headers[c.0] == nil { headers[c.0] = c.1 }
        return (headers, body)
    }

    private static func bodyText(headers: [String: String], body: String) -> (String, [MailLink]) {
        var plain: String?, html: String?
        collect(headers: headers, body: body, plain: &plain, html: &html, depth: 0)
        let links = html.map(anchors) ?? plain.map(bareLinks) ?? []
        if let plain, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (plain, links) }
        return (html.map(htmlToText) ?? "", links)
    }

    private static let anchor = try! NSRegularExpression(
        pattern: #"<a\b[^>]*?\bhref\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let altText = try! NSRegularExpression(pattern: #"\balt\s*=\s*["']([^"']*)["']"#, options: .caseInsensitive)
    private static let bareURL = try! NSRegularExpression(pattern: #"https?://[^\s<>"'\])]+"#)

    /// `<a href>` with its visible text (or an image button's alt text).
    static func anchors(_ html: String) -> [MailLink] {
        let ns = html as NSString
        return anchor.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { m in
            let inner = ns.substring(with: m.range(at: 2))
            var label = htmlToText(inner).replacingOccurrences(of: "\n", with: " ")
            if label.isEmpty, let alt = altText.firstMatch(in: inner, range: NSRange(location: 0, length: (inner as NSString).length)) {
                label = (inner as NSString).substring(with: alt.range(at: 1))
            }
            // Browsers drop tabs and newlines anywhere in a URL.
            let url = decodeEntities(ns.substring(with: m.range(at: 1))).replacingOccurrences(of: #"[\t\r\n]"#, with: "", options: .regularExpression)
            return MailLink(url: url, label: label)
        }
    }

    /// Plain-text mail: each URL labelled by the rest of its line.
    static func bareLinks(_ text: String) -> [MailLink] {
        text.split(separator: "\n").flatMap { line -> [MailLink] in
            let l = String(line), ns = l as NSString
            return bareURL.matches(in: l, range: NSRange(location: 0, length: ns.length)).map { m in
                let url = ns.substring(with: m.range).replacingOccurrences(of: #"[.,;:!?]+$"#, with: "", options: .regularExpression)
                return MailLink(url: url, label: l.replacingOccurrences(of: url, with: "").trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)))
            }
        }
    }

    private static func collect(headers: [String: String], body: String, plain: inout String?, html: inout String?, depth: Int) {
        let (type, params) = contentType(headers["content-type"] ?? "text/plain")
        if type.hasPrefix("multipart/"), let boundary = params["boundary"], depth < 8 {
            for chunk in body.components(separatedBy: "--" + boundary).dropFirst() {
                if chunk.hasPrefix("--") { break }
                let (h, b) = split(String(chunk.drop(while: { $0 != "\n" }).dropFirst()))  // rest of the boundary line
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

    static func htmlToText(_ html: String) -> String {
        var s = html
        for (pattern, template) in [
            (#"(?is)<(head|style|script|title)\b.*?</\1>"#, " "),
            (#"(?i)<br\s*/?>|</(p|div|tr|td|th|h\d|li|table|center)>"#, "\n"),
            (#"(?s)<[^>]+>"#, " "),
        ] {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return decodeEntities(s).split(separator: "\n")
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
