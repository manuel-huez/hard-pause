import Foundation

/// Exact network rules also receive the friendly browser redirect. Never matches
/// file: or internal browser pages, including Hard Pause's own local destination.
enum BrowserURLMatcher {
    static func rules(from snapshot: ProtectedServiceSnapshot) -> [ProtectedRules] {
        snapshot.blocks.compactMap { block in
            switch block.phase {
            case .active, .waitingForBreak, .waitingForFullUnlock: return block.draft.rules
            case .inactive, .breakActive: return nil
            }
        }
    }

    static func matches(
        _ url: URL, rules: [ProtectedRules], adultDomains: AdultDomainDatabase? = nil, hasAdultRating: Bool = false
    ) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = url.host,
            rules.contains(where: {
                !$0.allBlockedDomains.isEmpty || !$0.blockedURLPatterns.isEmpty || $0.blocksAdultWebsites
            })
        else { return false }
        let normalizedHost: String
        do {
            guard let value = try ProtectedPolicy.normalizeDomainChecked(host) else { return false }
            normalizedHost = value
        } catch {
            return true  // Do not allow a URL during an unexpected shared-core failure.
        }
        return rules.contains { rule in
            if rule.allowedDomains.contains(where: {
                DomainRule.browserHost($0) == DomainRule.browserHost(normalizedHost)
            }) {
                return false
            }
            return (rule.blocksAdultWebsites && (hasAdultRating || adultDomains?.contains(normalizedHost) == true))
                || rule.allBlockedDomains.contains(where: {
                    DomainRule.browserHost($0) == DomainRule.browserHost(normalizedHost)
                })
                || rule.blockedURLPatterns.contains { URLPatternRule.matches(url, pattern: $0) }
        }
    }
}
