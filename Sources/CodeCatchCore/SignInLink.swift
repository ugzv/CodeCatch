import Foundation

/// Finds the one action link in a sign-in, verification or password-reset mail
/// ("Confirm your sign-in", "Verify your email", magic links, "Reset password") —
/// not unsubscribe, help, social or tracking-pixel links. The subject decides the kind.
public enum SignInLink {
    public enum Kind: Sendable { case signIn, passwordReset }

    public static func find(in links: [MailLink], subject: String) -> (url: URL, kind: Kind)? {
        // "Your password was changed" is an alert, not a reset; course enrollment ("prijave") is not a sign-in.
        let kind: Kind
        if matches(resetContext, subject), !matches(passwordAlert, subject) { kind = .passwordReset }
        else if matches(context, subject) { kind = .signIn }
        else { return nil }
        var best: (url: URL, score: Int)?
        for link in links {
            guard let url = URL(string: link.url.trimmingCharacters(in: .whitespaces)), url.scheme?.lowercased() == "https",
                  let host = url.host, !host.isEmpty, !matches(excluded, link.url), !matches(excludedLabel, link.label) else { continue }
            // The button text must be the action; a matching path only ranks candidates.
            // In a sign-in alert, "Reset password" is the "this wasn't me" escape, not the sign-in.
            guard kind == .signIn ? matches(action, link.label) && !matches(resetAction, link.label)
                                  : matches(resetAction, link.label) || matches(action, link.label) else { continue }
            var score = 3
            if matches(actionPath, url.path + "?" + (url.query ?? "")) { score += 2 }
            if link.label.count <= 40 { score += 1 }
            if score > best?.score ?? 0 { best = (url, score) }
        }
        return best.map { ($0.url, kind) }
    }

    private static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: .caseInsensitive) }

    private static let context = rx(
        #"\bverif(y|ication)\b|confirm (your )?(sign|log|e-?mail|account|identity|device)|sign[- ]?in (link|request|attempt|to)|log[- ]?in (link|request|attempt|code|to)|(secure|magic|one-time) link|activate your|approve (your )?(sign|log)|is (this|it) you|potrdi|\bpovezava za prijavo\b|\bprijav[ao] v (vaš )?(račun|profil|naročniški center)\b|aktivir|bestätig|anmeld"#)
    private static let action = rx(
        #"\bverif(y|ication)\b|confirm|sign[- ]?in|log[- ]?in|magic|activat|approv|authori[sz]|yes|it'?s me|was me|continue|potrdi|prijava|prijavi|aktiviraj|bestätig|anmelden|click here to (sign|log|verify|confirm)"#)
    private static let actionPath = rx(#"verif|confirm|magic|log-?in|sign-?in|auth|activat|approv|token=|code=|otp|reset|password|recover"#)
    private static let resetContext = rx(
        #"password reset|reset (your |the )?password|(forgot|forgotten|change|set|create|choose) (a |your |the )?(new )?password|new password|passwort (zurücksetzen|vergessen)|ponastavi(tev)? gesl|pozablje\w* gesl|novo geslo"#)
    private static let passwordAlert = rx(
        #"password (was|has been) (changed|updated|reset)|password (changed|updated)|(changed|updated) your password|success|passwort (wurde )?geändert|geslo (je bilo )?spremenjeno"#)
    private static let resetAction = rx(#"\b(reset|change|password|passwort|geslo)\b|ponastavi|zurücksetzen|secure your"#)
    private static let excluded = rx(
        #"unsubscribe|optout|opt-out|preferences|privacy|/terms|/legal|/help|support\.|/support|mailto:|facebook\.com|twitter\.com|//x\.com|linkedin\.com|instagram\.com|youtube\.com|tiktok\.com/@|apps\.apple\.com|play\.google\.com|\.(png|jpe?g|gif|svg)(\?|$)"#)
    private static let excludedLabel = rx(#"unsubscribe|view (it )?in (your )?browser|privacy|terms|help center|contact us|didn'?t|not you|wasn'?t (me|you)|report"#)
}
