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
        ProtectedPolicy.normalizeDomain(input)
    }

    static func browserHost(_ value: String) -> String {
        guard let host = URL(string: "https://" + value)?.host
        else { return value.lowercased() }
        return host.lowercased()
    }

    static func isLiteralIPAddress(_ value: String) -> Bool {
        ProtectedPolicy.isLiteralIPAddress(value)
    }
}

enum URLPatternRule {
    static func normalize(_ input: String) -> String? {
        ProtectedPolicy.parseURLPattern(input)?.canonical
    }

    static func normalizeChecked(_ input: String) throws -> String? {
        try ProtectedPolicy.parseURLPatternChecked(input)?.canonical
    }

    static func exactDomain(from input: String) -> String? {
        ProtectedPolicy.exactDomain(from: input)
    }

    static func exactDomainChecked(from input: String) throws -> String? {
        try ProtectedPolicy.exactDomainChecked(from: input)
    }

    /// Exact OS coverage for common hosts; the browser still checks every subdomain.
    static func networkDomains(from input: String) -> [String] {
        ProtectedPolicy.networkDomains(from: input)
    }

    static func matches(_ url: URL, pattern input: String) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            return false
        }
        do {
            return try ProtectedPolicy.matchesURL(url, pattern: input)
        } catch {
            // Keep active browser rules effective if the shared core fails.
            return true
        }
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
