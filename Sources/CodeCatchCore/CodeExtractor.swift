import Foundation

/// Finds one-time codes in free text (SMS bodies, email subjects and bodies).
///
/// A text only yields a code when it talks about one (a keyword such as "code",
/// "verification", "koda"), and each number is scored by how it sits next to
/// that keyword, so order numbers, prices, dates and phone numbers lose.
public enum CodeExtractor {
    /// A recovery hint, not evidence that any particular number is a code.
    public static func hasCodeContext(in text: String) -> Bool {
        matches(keyword, text)
    }

    /// A code, and the text it was read from (as cleaned below) with the code as "#": the lines that
    /// tell one kind of message from another (what "Not a Code" remembers).
    public struct Detection: Equatable, Sendable {
        public let code: String
        public let context: String
    }

    public static func code(in text: String) -> String? { detect(in: text)?.code }

    public static func detect(in text: String) -> Detection? {
        // An origin-bound SMS ("@example.com #482913") names its code for machines: trust it.
        // Read before cleaning, which drops "@www.example.com" with the other addresses.
        if let m = origin.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
            m.range(at: 2).location != NSNotFound
        {
            // The whole text as read below, since the footer looks the same on every message the site sends.
            let code = (text as NSString).substring(with: m.range(at: 2))
            return Detection(code: code, context: maskingCopies(of: code, in: clean(text)))
        }
        let text = clean(text)
        let ns = text as NSString
        let keywords = keyword.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
        guard !keywords.isEmpty else { return nil }

        // Asked of the whole text, so once: a long mail has thousands of candidates.
        lazy var hasBooking = matches(bookingNumber, text)
        lazy var hasTransaction = matches(transactionNumber, text)
        var best: (code: String, score: Double, range: NSRange, context: NSRange)?
        for (regex, isNumeric) in [(numeric, true), (alphanumeric, false)] {
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let range = match.range(at: 1)
                let raw = ns.substring(with: range)
                if !isNumeric, !plausibleAlphanumeric(raw) { continue }
                let code = isNumeric ? raw.filter(\.isNumber) : raw

                // Cut from a window, not from everything on that side: copying the rest of a long mail per candidate stalled it.
                let before = ns.substring(with: NSRange(location: max(0, range.location - 640), length: min(640, range.location))).suffix(40)
                let after = ns.substring(with: NSRange(location: range.upperBound, length: min(640, ns.length - range.upperBound))).prefix(40)
                let line = line(around: range, in: ns)
                // A letters-only word set straight after the keyword is just the next word ("KODE RAHASIA utk",
                // "NEW API TOKEN CREATED"); "YOUR CODE IS SZBPM", "code: SZBPM" and "SZBPM is your code" name one.
                if !isNumeric, !raw.contains(where: \.isNumber), !matches(introducer, String(before)), !matches(explicitAfter, String(after)) {
                    continue
                }
                // A PIN beside a booking's confirmation number ("Confirmation: 5984715426 / PIN: 0260")
                // manages that booking, and an auth code beside a transaction ID ("Transaction ID: 121875559327 /
                // Auth Code: 051115") is a receipt's card approval: neither is one-time.
                if matches(pinLabel, String(before)), hasBooking { continue }
                if matches(approvalLabel, String(before)), hasTransaction { continue }
                let explicit = matches(explicitBefore, String(before)) || matches(explicitAfter, String(after))
                // Introduced on the keyword's line ("… Moj A1: 30718264", "Enkratno geslo … je 318842"),
                // or on the line above a code standing alone ("… Steam Guard code you need …:" over "6VCC5").
                let alone = aloneOnLine(range, in: ns)
                let leadStart = alone ? previousLineStart(line.location, in: ns) : line.location
                let lead = ns.substring(with: NSRange(location: leadStart, length: range.location - leadStart))
                let introduced = matches(introducer, lead) && matches(keyword, lead)
                // A letter code needs that explicit position, or an introduction and a digit
                // ("koda za aplikacijo dozdravnika.si: T3DQ"), so "verification: APPROVED" isn't one.
                // Marketing on the code's line or the one above ("Up to 80% off … Code: BULKE"): a coupon.
                let above = previousLineStart(line.location, in: ns)
                let nearby = ns.substring(with: NSRange(location: above, length: line.upperBound - above))
                if !isNumeric,
                    !(explicit || introduced && raw.contains(where: \.isNumber)) || matches(promo, nearby)
                        || matches(referenceLabel, String(before))
                {
                    continue
                }

                // Context is the code's own line, plus the line above when the code stands alone, and
                // the line below when that one names a code ("729565" over "Enter this verification
                // code…", not "…Your verification is complete"): "Account Login" two lines up, or
                // "confirm" under a subject naming a case number, says nothing.
                let below = alone ? nextLineEnd(line.upperBound, in: ns) : line.upperBound
                let end =
                    matches(codeNoun, ns.substring(with: NSRange(location: line.upperBound, length: below - line.upperBound)))
                    ? below : line.upperBound
                let context = NSRange(location: leadStart, length: end - leadStart)
                // Keywords are in text order: search for the first one reaching into the context, stop at the first past it.
                var first = 0
                var past = keywords.count
                while first < past {
                    let mid = (first + past) / 2
                    if keywords[mid].upperBound <= context.location { first = mid + 1 } else { past = mid }
                }
                let near = keywords[first...].prefix { $0.location < context.upperBound }.map { k in
                    k.upperBound <= range.location
                        ? range.location - k.upperBound
                        : k.location >= range.upperBound ? k.location - range.upperBound : 0
                }
                guard let distance = near.min() ?? (explicit ? 90 : nil) else { continue }

                var score: Double = [6: 3.0, 4: 2, 8: 2, 5: 1.5, 7: 1.5][code.count] ?? 1
                if isNumeric, code.count == 4, code.hasPrefix("19") || code.hasPrefix("20") { score -= 3 }
                score += max(0, 3 - Double(distance) / 30)
                if explicit { score += 4 }
                if matches(referenceLabel, String(before)) { score -= 5 }
                if introduced { score += 1.5 }
                if alone { score += 2 }
                if score >= 4, score > best?.score ?? 0 { best = (code, score, range, context) }
            }
        }
        return best.map { Detection(code: $0.code, context: maskingCopies(of: $0.code, in: masking($0.range, in: $0.context, of: ns))) }
    }

    /// `text` with every copy of `code` that stands as its own token written as "#": not the same digits
    /// inside a longer number ("1430" in 1143099), but right after Chinese text ("预约码为AB12CD") it counts.
    private static func maskingCopies(of code: String, in text: String) -> String {
        let copy = #"(?<![A-Za-z0-9])"# + NSRegularExpression.escapedPattern(for: code) + #"(?![A-Za-z0-9])"#
        return text.replacingOccurrences(of: copy, with: "#", options: [.regularExpression, .caseInsensitive])
    }

    /// `context` of `text` with `code` written as "#".
    private static func masking(_ code: NSRange, in context: NSRange, of text: NSString) -> String {
        text.substring(with: NSRange(location: context.location, length: code.location - context.location)) + "#"
            + text.substring(with: NSRange(location: code.upperBound, length: context.upperBound - code.upperBound))
    }

    /// How long the text says the code stays valid ("expires in 10 minutes", "velja 3 minute",
    /// "gültig für 1 Stunde", "valable 24 heures", "válido por 10 minutos"), 30 s to 24 h; nil when unstated.
    public static func validity(in text: String) -> TimeInterval? {
        let ns = text as NSString
        guard let m = lifetime.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
            let n = Double(ns.substring(with: m.range(at: 1)))
        else { return nil }
        let unit = ns.substring(with: m.range(at: 2)).lowercased()
        // Seconds and minutes by their first letters; every other unit the pattern takes is an hour.
        let seconds = n * (unit.hasPrefix("se") ? 1 : unit.hasPrefix("m") ? 60 : 3600)
        return (30...86400).contains(seconds) ? seconds : nil
    }

    /// The site of an origin-bound SMS: a final line "@example.com #123456".
    public static func originDomain(in text: String) -> String? {
        let ns = text as NSString
        guard let m = origin.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1)).lowercased()
    }

    private static let lifetime = rx(
        #"\b(?:expir\w*|v[aá]lid\w*|valable|caduc\w*|scad\w*|velja\w*|veljav\w*|gültig\w*|läuft|within|zapade\w*|poteče|istek\w*)\D{0,24}?\b(\d{1,3})\s*"#
            + #"(second\w*|secs?|segund\w*|sekund\w*|minutes?|mins?|minut\w*|hours?|hrs?|heures?|horas?|ore|ur[aeio]?|stunden?)\b"#,
        .caseInsensitive)
    /// Group 2 is the code when it looks like one (4–10 characters, a digit among them).
    private static let origin = rx(#"(?m)^@([a-z0-9-]+(?:\.[a-z0-9-]+)+)\s+#(?:(?=[a-z]*\d)([a-z0-9]{4,10})\b)?"#, .caseInsensitive)

    /// The service a code is for ("Google", "Revolut"), when the text names it.
    public static func service(in text: String) -> String? {
        let text = clean(text)
        for regex in servicePatterns {
            for match in regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                let name = (text as NSString).substring(with: match.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                // "OTP banka" names a bank; "Your code" or "Verification Code" names nothing.
                let words = name.split(separator: " ").map(String.init)
                let generic = words.allSatisfy { matches(keyword, $0) || stopwords.contains($0.lowercased()) }
                if name.count >= 2, !generic { return name }
            }
        }
        return nil
    }

    // MARK: - Patterns

    private static func rx(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// "code" (also German compounds: Sicherheitscode, Bestätigungscode), but not a postal, promo, area… code.
    private static let codeWord =
        #"(?<!(?:postal|zip|post|promo|discount|coupon|country|area|tax|source|referral|gift|voucher|swift|sort|qr|bar|dress) )(?:sicherheits|verifizierungs|bestätigungs|zugangs|anmelde|einmal|login|bestaetigungs|online)?codes?"#

    /// Words that say a text is about a code, grouped by the languages they serve. Stems are shared
    /// ("kod" alone is Slovenian, Polish, Czech, Turkish, Indonesian…), so a group is a label, not a
    /// switch. To add a language: add its words here and real messages to code-samples.txt.
    private static let keywords = [
        // English; Dutch and the German compounds (Sicherheitscode) come with codeWord
        codeWord, "passcode", "password", "pin", #"otp(?!\s*bank)"#, "token", "2fa", "mfa", "two[- ]factor", "one[- ]time",
        #"authenticat\w*"#, #"authori[sz]\w*"#, "security", "sign[- ]?in", "log[- ]?in",
        // Shared by English and the Romance languages
        #"verif\w*"#, #"confirm\w*"#,
        // kod, kód, koda, kode, kodas: the Slavic languages, Hungarian, Turkish, Indonesian, Lithuanian; kood, koodi: Estonian, Finnish
        #"k[oó]d\w*"#, #"\w*kood\w*"#,
        // Spanish, Portuguese, Italian, French
        "c[óo]digo", "codice", "clave", "contraseña", "senha", "mot de passe", "usage unique", #"vérif\w*"#, #"authentif\w*"#, "sécurité",
        // German
        "passwort", #"bestätig\w*"#, #"verifizier\w*"#, #"anmelde\w*"#,
        // Slovenian
        "geslo", "gesla", #"prijav\w*"#, #"potrd\w*"#, #"varnostn\w*"#, #"enkratn\w*"#,
        // Cyrillic (Russian, Ukrainian, Bulgarian, Serbian) and Greek
        #"код\w*"#, #"парол\w*"#, #"κωδικ\w*"#,
        // Turkish
        #"tek kullan\w*"#, #"[şs]ifre\w*"#, "do[ğg]rulama",
        // Vietnamese
        #"m[ãa] (?:x[áa]c (?:minh|nh[ậa]n|th[ựu]c)|k[íi]ch ho[ạa]t|OTP)"#,
    ]

    /// Scripts without spaces between words (Chinese, Japanese, Korean, Thai), and Hebrew,
    /// Arabic and Persian, which join "the" and prepositions to a word, match without word boundaries.
    private static let unspacedKeywords =
        unspacedCodeNouns + [
            // Japanese: password, one-time; Korean: authentication, password
            "パスワード", "ワンタイム", "인증", "비밀번호",
            // Hebrew: verification, password; Arabic: verify
            "אימות", "סיסמה", "تحقق",
        ]

    /// The ones that name a code itself, as `codeNoun` does in spaced scripts; not a QR, coupon, promo,
    /// invite or gift code, as `codeWord` isn't. (Not "bar" code: バー and 바 also end ウーバー and 알리바바.)
    private static let unspacedCodeNouns = [
        // Chinese
        "验证码", "驗證碼", "动态码", "動態碼", "校验码", "确认码", "认证码", "認證碼", "代码",
        // Japanese, Korean
        "(?<!QR|ＱＲ|クーポン|プロモーション|招待|ギフト)コード", "認証番号", "暗証番号", "인증번호", "(?<!QR ?|쿠폰|프로모션|초대|기프트)코드",
        // Hebrew, Arabic, Persian, Thai
        "קוד", "رمز", "كود", "کد", "รหัส",
    ]

    private static let keyword = rx(#"\b(?:"# + keywords.joined(separator: "|") + #")\b|"# + unspacedKeywords.joined(separator: "|"), .caseInsensitive)

    /// 4–8 digits, or two 3–4 digit groups ("482 913"). Not part of a longer
    /// number, price, date, time, phone number or "#order".
    private static let numeric = rx(
        #"(?<![\w.,$€£#+/@*])(?<!\d[ -])(\d{3}[ -]\d{3}|\d{4}[ -]\d{4}|\d{4,8})(?![\w%/@€$]|[.,:]\d|[ -]\d)"#)

    /// Letter codes ("K7PX2Q", "KXQ-7PM", "OJPIBYXGR", "83h344mx", Notion's "amivi-ndigo-rinit-raman");
    /// only trusted in an explicit "code: X" position.
    private static let alphanumeric = rx(#"(?<![\w-])([A-Za-z0-9]{3,4}-[A-Za-z0-9]{3,4}|[a-z]{3,8}(?:-[a-z]{3,8}){2,5}|[A-Za-z0-9]{4,10})(?![\w-])"#)

    private static func plausibleAlphanumeric(_ s: String) -> Bool {
        let letters = s.filter(\.isLetter)
        if s.contains("-"), s.split(separator: "-").count > 2 { return letters.allSatisfy(\.isLowercase) }  // word code
        if s.contains(where: \.isNumber) { return !letters.isEmpty }
        return letters.count >= 5 && letters.allSatisfy(\.isUppercase)
    }

    /// The code is introduced on its own line: "…Moj A1: 3071", "…s kartico *4321 je 318842".
    private static let introducer = rx(#"(?:[:=]|\b(?:is|je|ist|lautet|glasi|est|es|è|é))\s*$"#, .caseInsensitive)

    /// Marketing words: a letter "code" near them is a coupon, or an invite code sent to everyone.
    private static let promo = rx(
        #"\d\s*%|\b(?:off|discount|coupon|promo\w*|voucher|sale|save\s+up\s*to|upto|cashback|popust\w*|akcij\w*|rabatt?|invit(?:e|ation)\s+codes?)\b"#,
        .caseInsensitive)

    private static let explicitBefore = rx(
        "(?:" + codeWord + #"|kod[aoe]?|passcode|pin|otp|geslo|token|código|codice)\s*(?:is|je|ist|es|est|lautet)?\s*[:=\-–]?\s*$"#,
        .caseInsensitive)
    /// "Quote Number: 54321", "Ref: 482913", "card ending 4321", "text HELP to 466453", "Bestellung 123456",
    /// "commande n° 123456": a labelled reference, not a code.
    private static let referenceLabel = rx(
        #"\b(?:number|no|nr|št|stevilka|številka|r[eé]f\w*|id|order|invoice|quote|ticket|case|account|customer|client|member|phone|tel|mobile|fax|iban|card|ending(?: in)?|postal|zip|račun\w*|naročil\w*|pošiljk\w*|tracking|parcel|booking|reservation"#
            // German, French, Spanish, Portuguese, Italian: order, invoice, shipment, booking, number (not a German
            // compound that names a one-time code: Sicherheitsnummer, Transaktionsnummer…)
            + #"|bestellung|auftrag|sendung|rechnung|buchung|lieferung|(?!(?:(?:best(?:ä|ae)tig|sicherheit|verifi|authenti|transaktion|zugang|anmelde|login|einmal|freigabe)\w*|tan|pin)nummer)(?<!tan-|pin-)\w*nummer|commande|facture|colis|dossier|pedido|factura|fatura|encomenda|reserva|env[ií]o|ordine|fattura|prenotazione|spedizione|n[uú]m[eé]ro)"#
            + #"\s*[.:#]?\s*(?:(?:no\.?|n[°º])\s*)?[:#]?\s*$|\bref\w*\s+(?:code|kod\w*)\s*[:#]?\s*$|\b(?:text|txt|reply|send)\s+\w+\s+to\s*$"#,
        .caseInsensitive)

    private static let codeNoun = rx(
        #"\b(?:"# + codeWord + #"|k[oó]d\w*|passcode|pin|otp|token)\b|"# + unspacedCodeNouns.joined(separator: "|"), .caseInsensitive)
    private static let pinLabel = rx(#"\bpin\s*[:=]?\s*$"#, .caseInsensitive)
    private static let bookingNumber = rx(
        #"\b(?:confirmation|booking|reservation|buchung|rezervacij\w*)(?:\s+(?:number|no\.?|nr\.?|code))?\s*[:#]\s*\d{6,}"#, .caseInsensitive)
    private static let approvalLabel = rx(#"\b(?:auth(?:ori[sz]ation)?|approval)\s+code\s*[:#]?\s*$"#, .caseInsensitive)
    private static let transactionNumber = rx(#"\btransaction\s+(?:id|number|no\.?)\s*[:#]?\s*\w{6,}"#, .caseInsensitive)

    private static let explicitAfter = rx(
        #"^\s*(?:is|je|ist|es|est)\s+(?:your|the|vaša|vaš|vasa|vas|tvoja|tvoj|ihr|dein|la|le|el|il)\b"#,
        .caseInsensitive)

    private static let urlsAndEmails = rx(#"https?://\S+|www\.\S+|\S+@\S+\.\w+"#, .caseInsensitive)

    private static let name = #"([A-Z][\w&.'’-]*(?:\s+[A-Z][\w&.'’-]*)?)"#
    private static let codeKind =
        #"\s+(?i:(?:verification|security|login|sign[- ]in|authentication|confirmation|one[- ]time|access)\s+)?(?i:code|passcode|pin|otp)"#
    private static let servicePatterns = [
        rx(#"^\s*(?:<#>\s*)?[\[【]([^\]】\n]{2,30})[\]】]"#),
        rx(#"^\s*(?:<#>\s*)?([A-Z][\w&.'’ -]{1,24}?)\s*:\s"#),
        rx(#"(?i:is your)\s+"# + name + codeKind),
        rx(#"(?i:your)\s+"# + name + codeKind),
        rx(#"(?i:\b(?:to|for|from|with|into|at|on|v|za|pri|na|für|bei))\s+([A-Z][\w&.'’-]+(?:\s+[A-Z][\w&.'’-]+)?)"#),
    ]
    private static let stopwords: Set<String> = ["verification", "security", "login", "your", "the", "account", "access", "never", "don't"]

    // MARK: - Helpers

    private static func clean(_ text: String) -> String {
        // Arabic and Hebrew texts wrap codes in invisible direction marks: "‏78162106‏", "⁦291965⁩".
        var t = text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "[\u{200E}\u{200F}\u{202A}-\u{202E}\u{2066}-\u{2069}]", with: "", options: .regularExpression)
        t = urlsAndEmails.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: " ")
        // "验证码9316" / "認証コードは482913です": set digits apart from the words they're written against.
        return cjkDigitSeam.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: " ")
    }

    private static let cjk = #"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}\p{Thai}]"#
    private static let cjkDigitSeam = rx("(?<=" + cjk + #")(?=\d)|(?<=\d)(?="# + cjk + ")")

    /// Start of the nearest non-blank line above the line starting at `location`.
    private static func previousLineStart(_ location: Int, in ns: NSString) -> Int {
        var p = location
        while p > 0 {
            let prev = line(around: NSRange(location: p - 1, length: 0), in: ns)
            p = prev.location
            if !ns.substring(with: prev).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
        }
        return p
    }

    /// End of the nearest non-blank line below the line ending at `location`.
    private static func nextLineEnd(_ location: Int, in ns: NSString) -> Int {
        var p = location
        while p < ns.length {
            let next = line(around: NSRange(location: p, length: 0), in: ns)
            p = next.upperBound
            if !ns.substring(with: next).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
        }
        return p
    }

    /// The line around `range` as `lineRange(for:)` gives it, looking at most `reach` UTF-16 units each way:
    /// a mail that is one very long line was read whole for every candidate, which froze detection.
    private static func line(around range: NSRange, in ns: NSString, reach: Int = 1000) -> NSRange {
        let from = max(0, range.location - reach)
        let to = min(ns.length, range.upperBound + reach)
        let before = ns.rangeOfCharacter(from: .newlines, options: .backwards, range: NSRange(location: from, length: range.location - from))
        let start = before.location == NSNotFound ? from : before.upperBound
        let after = ns.rangeOfCharacter(from: .newlines, range: NSRange(location: range.upperBound, length: to - range.upperBound))
        guard after.location != NSNotFound else { return NSRange(location: start, length: to - start) }
        // "\r\n" ends a line as one.
        let crlf = ns.character(at: after.location) == 13 && after.upperBound < ns.length && ns.character(at: after.upperBound) == 10
        return NSRange(location: start, length: after.upperBound + (crlf ? 1 : 0) - start)
    }

    private static func aloneOnLine(_ range: NSRange, in ns: NSString) -> Bool {
        let line = ns.substring(with: line(around: range, in: ns))
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return trimmed == ns.substring(with: range)
    }
}
