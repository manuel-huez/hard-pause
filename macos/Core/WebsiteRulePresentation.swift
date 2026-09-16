struct WebsiteRulePresentation: Equatable, Identifiable {
    let title: String
    let includesSubdomains: Bool

    var id: String { title }

    static func rows(domains: [String], patterns: [String]) -> [Self] {
        let domainSet = Set(domains)
        let patternSet = Set(patterns)
        var seen = Set<String>()
        var rows: [Self] = []

        for domain in domains where seen.insert(domain).inserted {
            if let root = rootDomain(forGeneratedAlias: domain),
                domainSet.contains(root), patternSet.contains("*.\(root)")
            {
                continue
            }

            rows.append(
                Self(
                    title: domain,
                    includesSubdomains: patternSet.contains("*.\(domain)")
                )
            )
        }

        for pattern in patterns where seen.insert(pattern).inserted {
            if let domain = literalWildcardDomain(from: pattern), domainSet.contains(domain) {
                continue
            }
            rows.append(Self(title: pattern, includesSubdomains: false))
        }

        return rows
    }

    private static func rootDomain(forGeneratedAlias value: String) -> String? {
        guard value.hasPrefix("www."), value.count > 4 else { return nil }
        return String(value.dropFirst(4))
    }

    private static func literalWildcardDomain(from value: String) -> String? {
        guard value.hasPrefix("*."), value.count > 2 else { return nil }
        return String(value.dropFirst(2))
    }
}
