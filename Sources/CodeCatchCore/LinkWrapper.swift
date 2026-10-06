import Foundation

/// Company mail rewrites every link through a scanner (Microsoft Safe Links, Proofpoint, Google's /url?q=),
/// and senders through a click tracker (Amazon SES, Resend, Mandrill). Where the real destination is written
/// inside, the site check reads that, while the click still goes through, forwarded to the same place.
/// Opaque trackers (SendGrid's encrypted links) stay as they are.
public enum LinkWrapper {
    public static func destination(_ url: URL) -> URL {
        var url = url
        for _ in 0..<3 { guard let inner = unwrap(url) else { break }; url = inner }  // Safe Links around a Google redirect
        return url
    }

    private static func unwrap(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func param(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let inner: String?
        if host.hasSuffix(".safelinks.protection.outlook.com") {
            inner = param("url")
        } else if ["google.com", "www.google.com"].contains(host), url.path == "/url" {
            inner = param("q") ?? param("url")
        } else if host == "urldefense.proofpoint.com", url.path == "/v2/url" {
            // "https-3A__a.com_x" is "https%3A//a.com/x" with "%" and "/" swapped out.
            inner = param("u")?.replacingOccurrences(of: "-", with: "%").replacingOccurrences(of: "_", with: "/").removingPercentEncoding
        } else if host == "urldefense.com", let r = url.absoluteString.range(of: #"(?<=/v3/__).+?(?=__;)"#, options: .regularExpression) {
            inner = String(url.absoluteString[r])
        } else if ["awstrack.me", "resend-clicks-a.com"].contains(ServiceIdentity.registrable(host)),
                  let r = url.absoluteString.range(of: #"(?<=/C?L0/)[^/]+"#, options: .regularExpression) {
            // SES signs the path, so ".../L0/https:%2F%2Fa.com%2Fx/1/…" can't be edited to go elsewhere.
            inner = String(url.absoluteString[r]).removingPercentEncoding
        } else if host == "mandrillapp.com", url.path.hasPrefix("/track/click/"),
                  let data = param("p").flatMap({ Data(base64Encoded: $0.padding(toLength: ($0.count + 3) / 4 * 4, withPad: "=", startingAt: 0)) }),
                  let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = (outer["p"] as? String).flatMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }) {
            inner = payload["url"] as? String
        } else {
            return nil
        }
        guard let inner, let target = URL(string: inner), ["http", "https"].contains(target.scheme?.lowercased()),
              target.host?.isEmpty == false else { return nil }
        return target
    }
}
