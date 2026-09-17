import CryptoKit
import Foundation

/// A domain list is data, never an instruction or a URL to fetch.
struct AdultDomainDatabase: Sendable {
    static let maximumBytes = PortableDomainList.maximumBytes
    let domains: Set<String>
    let skippedEntries: Int

    init(data: Data, supplementData: Data? = nil, minimumCount: Int = 1_000) throws {
        let upstream: PortableDomainList
        do {
            upstream = try PortableDomainList(
                data: data,
                format: .blockListProject(minimumCount: minimumCount)
            )
        } catch {
            throw AdultDatabaseError.invalidData
        }
        var mergedDomains = upstream.domains
        if let supplementData {
            do {
                let supplement = try PortableDomainList(
                    data: supplementData,
                    format: .hardPauseSupplement(category: "adult")
                )
                mergedDomains.formUnion(supplement.domains)
            } catch {
                throw AdultDatabaseError.invalidData
            }
        }
        domains = mergedDomains
        skippedEntries = upstream.skippedEntries
    }

    func contains(_ host: String) -> Bool {
        PortableDomainList.contains(
            canonicalASCIIHost: DomainRule.browserHost(host),
            in: domains
        )
    }
}

enum AdultDatabaseError: Error {
    case invalidData
    case invalidResponse
}

enum AdultPageRating {
    // Reads only the current page's declared rating. No page text or requests.
    static let script = """
        (() => Array.from(document.head?.querySelectorAll('meta') || []).some(m =>
          ((m.getAttribute('name') || m.getAttribute('http-equiv') || '').trim().toLowerCase() === 'rating') &&
          ((m.getAttribute('content') || '').trim().toUpperCase() === 'RTA-5042-1996-1400-1577-RTA')
        ))()
        """
}

/// Positive page ratings only. Keys are URL hashes, never plain addresses.
/// Reads do not extend the lifetime; the category must still be active.
struct AdultRatingCache {
    private var expirations: [String: TimeInterval] = [:]
    private let lifetime: TimeInterval
    private let capacity: Int

    init(
        data: Data? = nil, lifetime: TimeInterval = 86_400, capacity: Int = 2_048,
        now: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.lifetime = lifetime
        self.capacity = capacity
        if let data, data.count <= 512 * 1_024,
            let saved = try? JSONDecoder().decode([String: TimeInterval].self, from: data), saved.count <= capacity
        {
            expirations = saved.filter { key, expiry in
                key.count == 64 && key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
                    && expiry > now && expiry <= now + lifetime
            }
        }
    }

    func encoded(now: TimeInterval = Date().timeIntervalSince1970) throws -> Data {
        try JSONEncoder().encode(expirations.filter { $0.value > now })
    }

    mutating func contains(_ url: URL, now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard let key = Self.key(url), let expiry = expirations[key] else { return false }
        guard now < expiry else {
            expirations.removeValue(forKey: key)
            return false
        }
        return true
    }

    mutating func record(_ url: URL, now: TimeInterval = Date().timeIntervalSince1970) {
        guard capacity > 0, let key = Self.key(url), !contains(url, now: now) else { return }
        expirations = expirations.filter { $0.value > now }
        if expirations.count >= capacity, let oldest = expirations.min(by: { $0.value < $1.value })?.key {
            expirations.removeValue(forKey: oldest)
        }
        expirations[key] = now + lifetime
    }

    private static func key(_ url: URL) -> String? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.host != nil
        else { return nil }
        components.user = nil
        components.password = nil
        guard let canonical = components.string else { return nil }
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
