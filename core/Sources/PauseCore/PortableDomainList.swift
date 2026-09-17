import Foundation

enum PortableDomainListError: Error, Equatable, Sendable {
    case invalidData
}

/// A bounded, domain-only list. It contains no fetch URL or executable instructions.
struct PortableDomainList: Equatable, Sendable {
    static let maximumBytes = 32 * 1024 * 1024
    static let maximumEntries = 1_500_000
    static let maximumSupplementBytes = 1024 * 1024
    static let maximumSupplementEntries = 10_000

    enum Format: Equatable, Sendable {
        case blockListProject(minimumCount: Int)
        case hardPauseSupplement(category: String)
    }

    let domains: Set<String>
    let skippedEntries: Int
    let metadata: [String: String]

    init(data: Data, format: Format) throws {
        let maximumBytes =
            switch format {
            case .blockListProject:
                Self.maximumBytes
            case .hardPauseSupplement:
                Self.maximumSupplementBytes
            }
        guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8) else {
            throw PortableDomainListError.invalidData
        }

        var domains = Set<String>()
        var entries = 0
        var skipped = 0
        var metadata: [String: String] = [:]
        var duplicateMetadata = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let declaration = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                if let separator = declaration.firstIndex(of: ":") {
                    let key = declaration[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
                    let value = declaration[declaration.index(after: separator)...]
                        .trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty else {
                        throw PortableDomainListError.invalidData
                    }
                    if metadata.updateValue(value, forKey: key) != nil {
                        duplicateMetadata.insert(key)
                    }
                }
                continue
            }
            guard !trimmed.isEmpty else { continue }
            entries += 1
            guard entries <= Self.maximumEntries else {
                throw PortableDomainListError.invalidData
            }
            let domain = trimmed.lowercased()
            guard Self.isValidDomain(domain) else {
                skipped += 1
                continue
            }
            domains.insert(domain)
        }

        guard let declaredCount = Self.declaredCount(in: metadata), declaredCount == entries else {
            throw PortableDomainListError.invalidData
        }
        switch format {
        case .blockListProject(let minimumCount):
            guard minimumCount >= 0, domains.count >= minimumCount, skipped <= entries / 1_000 else {
                throw PortableDomainListError.invalidData
            }
        case .hardPauseSupplement(let category):
            guard metadata["format"] == "hard-pause-domain-list-v1",
                metadata["category"]?.lowercased() == category.lowercased(),
                Self.isISODate(metadata["revision"]),
                !(metadata["license"]?.isEmpty ?? true),
                !(metadata["provenance"]?.isEmpty ?? true),
                duplicateMetadata.isEmpty,
                entries <= Self.maximumSupplementEntries,
                skipped == 0,
                domains.count == entries
            else {
                throw PortableDomainListError.invalidData
            }
        }

        self.domains = domains
        skippedEntries = skipped
        self.metadata = metadata
    }

    func contains(canonicalASCIIHost host: String) -> Bool {
        Self.contains(canonicalASCIIHost: host, in: domains)
    }

    static func contains(canonicalASCIIHost host: String, in domains: Set<String>) -> Bool {
        var candidate = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        while candidate.contains(".") {
            if domains.contains(candidate) { return true }
            guard let separator = candidate.firstIndex(of: ".") else { break }
            candidate.removeSubrange(...separator)
        }
        return false
    }

    static func isValidDomain(_ value: String) -> Bool {
        guard value.utf8.count <= 253, value.contains(".") else { return false }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard let last = labels.last, last.contains(where: { $0.isLetter }) else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy {
                    (97...122).contains($0) || (48...57).contains($0) || $0 == 45
                }
        }
    }

    private static func declaredCount(in metadata: [String: String]) -> Int? {
        metadata["entries"].flatMap {
            Int($0.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces))
        }
    }

    private static func isISODate(_ value: String?) -> Bool {
        guard let value, value.count == 10 else { return false }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: value) != nil
    }
}
