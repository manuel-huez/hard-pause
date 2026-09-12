import Darwin
import Foundation

struct ClockReading: Equatable, Sendable {
    let wallTime: Date
    let continuousTime: TimeInterval
    let bootIdentifier: String?
}

enum SystemClock {
    static func read() -> ClockReading {
        ClockReading(
            wallTime: Date(),
            continuousTime: continuousTime(),
            bootIdentifier: bootIdentifier
        )
    }

    private static let timebase: mach_timebase_info_data_t = {
        var value = mach_timebase_info_data_t()
        mach_timebase_info(&value)
        return value
    }()

    private static func continuousTime() -> TimeInterval {
        let ticks = mach_continuous_time()
        return Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    private static let bootIdentifier: String? = {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        return String(cString: buffer)
    }()
}

enum DomainRule {
    static func normalize(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, !value.contains("*") else { return nil }
        while value.hasSuffix(".") { value.removeLast() }
        guard !value.isEmpty else { return nil }

        if isLiteralIPAddress(value) { return value }
        if value.hasPrefix("["), value.hasSuffix("]") {
            let unwrapped = String(value.dropFirst().dropLast())
            return isLiteralIPAddress(unwrapped) ? unwrapped : nil
        }

        let candidate = value.contains("://") ? value : "https://\(value)"
        guard var host = URLComponents(string: candidate)?.host?.lowercased() else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("["), host.hasSuffix("]") {
            let unwrapped = String(host.dropFirst().dropLast())
            return isLiteralIPAddress(unwrapped) ? unwrapped : nil
        }
        if isLiteralIPAddress(host) { return host }
        guard !host.isEmpty, host.count <= 253, !host.contains("_"), !host.contains(" ") else {
            return nil
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty,
            labels.allSatisfy({ label in
                !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                    && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
            })
        else { return nil }
        return host
    }

    static func browserHost(_ value: String) -> String {
        guard let host = URL(string: "https://" + value)?.host
        else { return value.lowercased() }
        return host.lowercased()
    }

    static func isLiteralIPAddress(_ value: String) -> Bool {
        var address4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &address4) }) == 1 { return true }
        var address6 = in6_addr()
        return value.withCString { inet_pton(AF_INET6, $0, &address6) } == 1
    }
}

enum URLPatternRule {
    private enum HostPattern {
        case exact(String)
        case subdomains(of: String)
    }

    private struct ParsedPattern {
        let scheme: String?
        let host: HostPattern
        let canonicalHost: String
        let port: Int?
        let resource: String?

        var canonical: String {
            let schemePrefix = scheme.map { "\($0)://" } ?? ""
            let portSuffix = port.map { ":\($0)" } ?? ""
            return schemePrefix + canonicalHost + portSuffix + (resource ?? "")
        }
    }

    static func normalize(_ input: String) -> String? {
        parse(input)?.canonical
    }

    static func exactDomain(from input: String) -> String? {
        guard let pattern = parse(input), pattern.port == nil, pattern.resource == nil else {
            return nil
        }
        guard case .exact(let host) = pattern.host else { return nil }
        return host
    }

    static func matches(_ url: URL, pattern input: String) -> Bool {
        guard let pattern = parse(input), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            var host = url.host?.lowercased()
        else { return false }
        while host.hasSuffix(".") { host.removeLast() }

        if let scheme = pattern.scheme, url.scheme?.lowercased() != scheme { return false }
        switch pattern.host {
        case .exact(let expectedHost):
            guard host == DomainRule.browserHost(expectedHost) else { return false }
        case .subdomains(let suffix):
            let asciiSuffix = DomainRule.browserHost(suffix)
            guard host.hasSuffix(".\(asciiSuffix)"), host != asciiSuffix else { return false }
        }
        if let port = pattern.port, effectivePort(of: url) != port { return false }
        guard let resource = pattern.resource else { return true }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.percentEncodedPath ?? url.path
        if !resource.contains("*"), !resource.contains("?"), !resource.contains("#") {
            let decoded = path.removingPercentEncoding ?? path
            let expected = resource.removingPercentEncoding ?? resource
            return decoded == expected || decoded.hasPrefix("\(expected)/")
        }

        var actualResource = path
        if let query = components?.percentEncodedQuery { actualResource += "?\(query)" }
        if let fragment = components?.percentEncodedFragment { actualResource += "#\(fragment)" }
        return globMatches(resource, actualResource)
            || globMatches(resource, actualResource.removingPercentEncoding ?? actualResource)
    }

    private static func parse(_ input: String) -> ParsedPattern? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
            value.count <= ProtectedBlockLimits.maximumURLPatternLength,
            isSafePatternText(value)
        else {
            return nil
        }

        let scheme: String?
        let remainder: Substring
        if let separator = value.range(of: "://") {
            let candidate = String(value[..<separator.lowerBound]).lowercased()
            guard ["http", "https"].contains(candidate) else { return nil }
            scheme = candidate
            remainder = value[separator.upperBound...]
        } else {
            guard !value.contains("://") else { return nil }
            scheme = nil
            remainder = value[...]
        }

        let resourceStart = remainder.firstIndex { character in
            character == "/" || character == "?" || character == "#"
        }
        let authority = resourceStart.map { remainder[..<$0] } ?? remainder[...]
        var resource = resourceStart.map { String(remainder[$0...]) }
        if let suffix = resource, suffix.hasPrefix("?") || suffix.hasPrefix("#") { resource = "/" + suffix }
        guard !authority.isEmpty, !authority.contains("@") else { return nil }

        guard let parsedAuthority = parseAuthority(String(authority)) else { return nil }
        if resource == "/" { resource = nil }
        if let candidate = resource,
            !candidate.contains("*"), !candidate.contains("?"), !candidate.contains("#")
        {
            while resource?.count ?? 0 > 1, resource?.hasSuffix("/") == true {
                resource?.removeLast()
            }
        }

        return ParsedPattern(
            scheme: scheme,
            host: parsedAuthority.host,
            canonicalHost: parsedAuthority.canonicalHost,
            port: parsedAuthority.port,
            resource: resource
        )
    }

    private static func parseAuthority(
        _ authority: String
    ) -> (host: HostPattern, canonicalHost: String, port: Int?)? {
        let hostInput: String
        let port: Int?

        if authority.hasPrefix("[") {
            guard let closingBracket = authority.firstIndex(of: "]") else { return nil }
            hostInput = String(authority[authority.index(after: authority.startIndex)..<closingBracket])
            let suffix = authority[authority.index(after: closingBracket)...]
            guard suffix.isEmpty || suffix.hasPrefix(":"), !suffix.dropFirst().contains(":") else {
                return nil
            }
            port = suffix.isEmpty ? nil : parsePort(String(suffix.dropFirst()))
            if !suffix.isEmpty, port == nil { return nil }
            guard DomainRule.isLiteralIPAddress(hostInput) else { return nil }
            return (.exact(hostInput.lowercased()), "[\(hostInput.lowercased())]", port)
        }

        if DomainRule.isLiteralIPAddress(authority) {
            let host = authority.lowercased()
            return (.exact(host), host.contains(":") ? "[\(host)]" : host, nil)
        }

        let colon = authority.lastIndex(of: ":")
        if let colon {
            guard authority[..<colon].firstIndex(of: ":") == nil else { return nil }
            hostInput = String(authority[..<colon])
            port = parsePort(String(authority[authority.index(after: colon)...]))
            guard port != nil else { return nil }
        } else {
            hostInput = authority
            port = nil
        }

        if hostInput.hasPrefix("*.") {
            let suffixInput = String(hostInput.dropFirst(2))
            guard let suffix = DomainRule.normalize(suffixInput),
                !DomainRule.isLiteralIPAddress(suffix),
                !suffix.contains(":")
            else {
                return nil
            }
            return (.subdomains(of: suffix), "*.\(suffix)", port)
        }

        guard !hostInput.contains("*"), let host = DomainRule.normalize(hostInput) else {
            return nil
        }
        let canonicalHost = host.contains(":") ? "[\(host)]" : host
        return (.exact(host), canonicalHost, port)
    }

    private static func parsePort(_ input: String) -> Int? {
        guard !input.isEmpty, input.allSatisfy(\.isNumber), let port = Int(input),
            (1...65_535).contains(port)
        else {
            return nil
        }
        return port
    }

    private static func effectivePort(of url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    private static func isSafePatternText(_ value: String) -> Bool {
        !value.contains("\\")
            && value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
            && value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
    }

    private static func globMatches(_ pattern: String, _ value: String) -> Bool {
        let patternBytes = Array(pattern.utf8)
        let valueBytes = Array(value.utf8)
        var patternIndex = 0
        var valueIndex = 0
        var starIndex: Int?
        var valueAfterStar = 0

        while valueIndex < valueBytes.count {
            if patternIndex < patternBytes.count, patternBytes[patternIndex] == valueBytes[valueIndex] {
                patternIndex += 1
                valueIndex += 1
            } else if patternIndex < patternBytes.count, patternBytes[patternIndex] == 0x2A {
                starIndex = patternIndex
                patternIndex += 1
                valueAfterStar = valueIndex
            } else if let starIndex {
                patternIndex = starIndex + 1
                valueAfterStar += 1
                valueIndex = valueAfterStar
            } else {
                return false
            }
        }

        while patternIndex < patternBytes.count, patternBytes[patternIndex] == 0x2A {
            patternIndex += 1
        }
        return patternIndex == patternBytes.count
    }
}

enum StarterAdultRules {
    static let version = 1

    // This small bundled starter set is neither a classifier nor complete.
    static let domains = [
        "pornhub.com", "www.pornhub.com",
        "xvideos.com", "www.xvideos.com",
        "xnxx.com", "www.xnxx.com",
        "redtube.com", "www.redtube.com",
        "youporn.com", "www.youporn.com",
    ]
}
