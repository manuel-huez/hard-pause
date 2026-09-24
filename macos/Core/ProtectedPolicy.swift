import Darwin
import Foundation

/// Codable storage remains in the native models. Policy decisions use the shared core.
enum ProtectedPolicy {
    struct ParsedPattern: Decodable {
        let scheme: String?
        let host: String
        let subdomains: Bool
        let port: Int?
        let resource: String?
        let canonical: String
    }

    private struct TextArguments: Encodable { let value: String }
    private struct ValueResult<Value: Decodable>: Decodable { let value: Value }

    private struct URLMatchArguments: Encodable {
        struct BrowserURL: Encodable {
            let scheme: String?
            let host: String?
            let port: Int?
            let path: String
            let query: String?
            let fragment: String?

            init(_ url: URL) {
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                scheme = url.scheme
                host = url.host
                port = url.port
                path = components?.percentEncodedPath ?? url.path
                query = components?.percentEncodedQuery
                fragment = components?.percentEncodedFragment
            }
        }

        let pattern: String
        let url: BrowserURL
    }
    private struct RulesResult: Decodable { let rules: ProtectedRules }
    private struct EmptyResult: Decodable {}
    private struct NameResult: Decodable { let name: String }

    private struct RuleAdditions: Encodable {
        let rules: ProtectedRules
        let domains: [String]
        let urlPatterns: [String]
        let applications: [ProtectedApplication]
        let adultWebsites: Bool
    }

    private struct RulesComparison: Encodable {
        let current: ProtectedRules
        let previous: ProtectedRules
    }

    private struct RulesValidation: Encodable {
        let rules: ProtectedRules
        let allowLegacyApplicationIdentity: Bool
    }

    private struct WireDraft: Encodable {
        let name: String
        let rules: ProtectedRules
        let protectionMode: ProtectionMode
        let breakDelay: String
        let fullUnlockDelay: String
        let breakDuration: String
        let elapsedDuration: String?

        init(_ draft: ProtectedBlockDraft) {
            name = draft.name
            rules = draft.rules
            protectionMode = draft.protectionMode
            breakDelay = String(draft.breakDelay)
            fullUnlockDelay = String(draft.fullUnlockDelay)
            breakDuration = String(draft.breakDuration)
            elapsedDuration = draft.elapsedDuration.map { String($0) }
        }
    }

    private struct DraftValidation: Encodable {
        let draft: WireDraft
        let mutation: Bool
        let allowLegacyApplicationIdentity: Bool
    }

    static func normalizeDomain(_ input: String) -> String? {
        try? normalizeDomainChecked(input)
    }

    static func normalizeDomainChecked(_ input: String) throws -> String? {
        let result: ValueResult<String?> = try RustCoreBridge.call(
            "policy.normalize_domain", TextArguments(value: input)
        )
        return result.value
    }

    static func isLiteralIPAddress(_ input: String) -> Bool {
        do {
            let result: ValueResult<Bool> = try RustCoreBridge.call(
                "policy.is_literal_ip_address", TextArguments(value: input)
            )
            return result.value
        } catch {
            // Enforcement must still route literal addresses to PF if the bridge fails.
            var address4 = in_addr()
            if input.withCString({ inet_pton(AF_INET, $0, &address4) }) == 1 { return true }
            var address6 = in6_addr()
            return input.withCString { inet_pton(AF_INET6, $0, &address6) } == 1
        }
    }

    static func parseURLPattern(_ input: String) -> ParsedPattern? {
        try? parseURLPatternChecked(input)
    }

    static func parseURLPatternChecked(_ input: String) throws -> ParsedPattern? {
        let result: ValueResult<ParsedPattern?> = try RustCoreBridge.call(
            "policy.parse_url_pattern", TextArguments(value: input)
        )
        return result.value
    }

    static func exactDomain(from input: String) -> String? {
        try? exactDomainChecked(from: input)
    }

    static func exactDomainChecked(from input: String) throws -> String? {
        let result: ValueResult<String?> = try RustCoreBridge.call(
            "policy.exact_domain", TextArguments(value: input)
        )
        return result.value
    }

    static func matchesURL(_ url: URL, pattern: String) throws -> Bool {
        let result: ValueResult<Bool> = try RustCoreBridge.call(
            "policy.matches_url", URLMatchArguments(pattern: pattern, url: .init(url))
        )
        return result.value
    }

    static func networkDomains(from input: String) -> [String] {
        let result: ValueResult<[String]>? = try? RustCoreBridge.call(
            "policy.network_domains", TextArguments(value: input)
        )
        return result?.value ?? []
    }

    static func normalizeRules(_ rules: ProtectedRules) -> ProtectedRules {
        let result: RulesResult? = try? RustCoreBridge.call("policy.normalize_rules", rules)
        return result?.rules ?? invalidRules(rules)
    }

    static func addRules(
        _ rules: ProtectedRules,
        domains: [String],
        urlPatterns: [String],
        applications: [ProtectedApplication],
        adultWebsites: Bool
    ) -> ProtectedRules {
        let result: RulesResult? = try? RustCoreBridge.call(
            "policy.add_rules",
            RuleAdditions(
                rules: rules, domains: domains, urlPatterns: urlPatterns,
                applications: applications, adultWebsites: adultWebsites
            )
        )
        return result?.rules ?? invalidRules(rules)
    }

    static func includesAllRules(_ current: ProtectedRules, in previous: ProtectedRules) -> Bool {
        let result: ValueResult<Bool>? = try? RustCoreBridge.call(
            "policy.includes_all_rules", RulesComparison(current: current, previous: previous)
        )
        return result?.value == true
    }

    static func validateRules(
        _ rules: ProtectedRules, allowLegacyApplicationIdentity: Bool
    ) throws {
        do {
            let _: EmptyResult = try RustCoreBridge.call(
                "policy.validate_rules",
                RulesValidation(
                    rules: rules,
                    allowLegacyApplicationIdentity: allowLegacyApplicationIdentity
                )
            )
        } catch {
            throw policyError(error)
        }
    }

    static func validateDraft(
        _ draft: ProtectedBlockDraft,
        mutation: Bool,
        allowLegacyApplicationIdentity: Bool
    ) throws -> String {
        do {
            let result: NameResult = try RustCoreBridge.call(
                "policy.validate_draft",
                DraftValidation(
                    draft: WireDraft(draft), mutation: mutation,
                    allowLegacyApplicationIdentity: allowLegacyApplicationIdentity
                )
            )
            return result.name
        } catch {
            throw policyError(error)
        }
    }

    private static func invalidRules(_ rules: ProtectedRules) -> ProtectedRules {
        // Nonthrowing callers must produce a draft that persistence validation rejects.
        ProtectedRules(
            blockedDomains: rules.blockedDomains + [""],
            blockedApplications: rules.blockedApplications,
            blockedAdultDomains: rules.blockedAdultDomains,
            adultRulesVersion: rules.adultRulesVersion,
            blockedURLPatterns: rules.blockedURLPatterns,
            blocksAdultWebsites: rules.blocksAdultWebsites
        )
    }

    private static func policyError(_ error: Error) -> ProtectedStateError {
        guard case RustCoreBridge.Failure.rejected(let code) = error else {
            return .invalid("The policy validation is unavailable.")
        }
        switch code {
        case "too_many_rules": return .invalid("The block has too many rules.")
        case "no_rules": return .invalid("Add at least one website or application.")
        case "invalid_domain": return .invalid("The block contains an invalid or duplicate domain.")
        case "invalid_url_pattern": return .invalid("The block contains an invalid or duplicate URL pattern.")
        case "invalid_adult_rules": return .invalid("The adult website rules are inconsistent.")
        case "duplicate_application": return .invalid("The block contains a duplicate application.")
        case "invalid_application": return .invalid("The block contains an invalid application.")
        case "invalid_application_identity": return .invalid("An application identity is invalid.")
        case "missing_application_identity":
            return .invalid("Choose the application again so Hard Pause can save its signed identity.")
        case "invalid_mutation_name": return .invalid("Enter a block name with 120 characters or fewer.")
        case "invalid_saved_name": return .invalid("A saved block name is invalid.")
        case "invalid_break_delay": return .invalid("The break delay is outside the supported range.")
        case "invalid_full_unlock_delay": return .invalid("The full unlock delay is outside the supported range.")
        case "invalid_break_duration": return .invalid("The break duration is outside the supported range.")
        case "invalid_fixed_duration": return .invalid("The fixed duration is outside the supported range.")
        case "invalid_mutation_fixed_plan": return .invalid("A Hard Pause plan cannot end automatically.")
        case "invalid_saved_fixed_plan": return .invalid("A saved Hard Pause plan cannot end automatically.")
        default: return .invalid("The policy validation is unavailable.")
        }
    }
}
