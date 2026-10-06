/// Where a host's public suffix starts ("co.uk", "github.io"), by the Public Suffix List's rules:
/// the longest matching rule wins, "*.x" covers any one label before "x", and "!y" excepts "y" from a wildcard.
enum PublicSuffix {
    private struct Rules { var exact = Set<String>(), wildcard = Set<String>(), exception = Set<String>() }

    private static let rules = list.split(separator: "\n").reduce(into: Rules()) { rules, line in
        if line.hasPrefix("!") { rules.exception.insert(String(line.dropFirst())) }
        else if line.hasPrefix("*.") { rules.wildcard.insert(String(line.dropFirst(2))) }
        else { rules.exact.insert(String(line)) }
    }

    /// How many trailing labels are the public suffix; 1 when no rule matches (the list's default "*").
    static func length(of labels: [Substring]) -> Int {
        for i in labels.indices {
            let suffix = labels[i...].joined(separator: ".")
            if rules.exception.contains(suffix) { return labels.count - i - 1 }
            if rules.exact.contains(suffix) || i + 1 < labels.count && rules.wildcard.contains(labels[(i + 1)...].joined(separator: ".")) {
                return labels.count - i
            }
        }
        return 1
    }
}
