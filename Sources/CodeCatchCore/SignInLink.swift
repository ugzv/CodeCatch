import Foundation

/// Finds the one action link in a sign-in or verification mail ("Confirm your
/// sign-in", "Verify your email", magic links) — not unsubscribe, help, social
/// or tracking-pixel links. Only mails that are about signing in qualify.
public enum SignInLink {
    public static func find(in links: [MailLink], subject: String) -> URL? {
        // The subject decides: require sign-in context, not course/event enrollment ("prijave").
        guard matches(context, subject) else { return nil }
        var best: (url: URL, score: Int)?
        for link in links {
            guard let url = URL(string: link.url.trimmingCharacters(in: .whitespaces)), url.scheme?.lowercased() == "https",
                  let host = url.host, !host.isEmpty, !matches(excluded, link.url), !matches(excludedLabel, link.label) else { continue }
            // The button text must be the action; a matching path only ranks candidates.
            guard matches(action, link.label) else { continue }
            var score = 3
            if matches(actionPath, url.path + "?" + (url.query ?? "")) { score += 2 }
            if link.label.count <= 40 { score += 1 }
            if score > best?.score ?? 0 { best = (url, score) }
        }
        return best?.url
    }

    private static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: .caseInsensitive) }

    private static let context = rx(
        #"\bverif(y|ication)\b|confirm (your )?(sign|log|e-?mail|account|identity|device)|sign[- ]?in (link|request|attempt|to)|log[- ]?in (link|request|attempt|code|to)|(secure|magic|one-time) link|activate your|approve (your )?(sign|log)|is (this|it) you|password reset|reset your password|potrdi|\bpovezava za prijavo\b|\bprijav[ao] v (vaš )?(račun|profil|naročniški center)\b|aktivir|bestätig|anmeld"#)
    private static let action = rx(
        #"\bverif(y|ication)\b|confirm|sign[- ]?in|log[- ]?in|magic|activat|approv|authori[sz]|yes|it'?s me|was me|continue|reset|potrdi|prijava|prijavi|aktiviraj|bestätig|anmelden|click here to (sign|log|verify|confirm)"#)
    private static let actionPath = rx(#"verif|confirm|magic|log-?in|sign-?in|auth|activat|approv|token=|code=|otp|reset"#)
    private static let excluded = rx(
        #"unsubscribe|optout|opt-out|preferences|privacy|/terms|/legal|/help|support\.|/support|mailto:|facebook\.com|twitter\.com|//x\.com|linkedin\.com|instagram\.com|youtube\.com|tiktok\.com/@|apps\.apple\.com|play\.google\.com|\.(png|jpe?g|gif|svg)(\?|$)"#)
    private static let excludedLabel = rx(#"unsubscribe|view (it )?in (your )?browser|privacy|terms|help center|contact us|didn'?t|not you|wasn'?t (me|you)|report"#)
}
