import Foundation

enum PortableDomainListError: Error, Equatable, Sendable {
    case invalidData
}

private final class PortableDomainIndex: @unchecked Sendable {
    let pointer: OpaquePointer

    init(data: Data, format: PortableDomainList.Format) throws {
        var result: OpaquePointer?
        let category = format.category.data(using: .utf8) ?? Data()
        let status = data.withUnsafeBytes { listBytes in
            category.withUnsafeBytes { categoryBytes in
                hp_domain_index_create(
                    listBytes.bindMemory(to: UInt8.self).baseAddress,
                    listBytes.count,
                    format.kind,
                    format.minimumCount,
                    categoryBytes.bindMemory(to: UInt8.self).baseAddress,
                    categoryBytes.count,
                    &result
                )
            }
        }
        guard status == 0, let result else { throw PortableDomainListError.invalidData }
        pointer = result
    }

    deinit { hp_domain_index_free(pointer) }

    func contains(_ host: String) -> Bool {
        var contains: UInt8 = 0
        let bytes = Array(host.utf8)
        let status = bytes.withUnsafeBufferPointer { buffer in
            hp_domain_index_contains(pointer, buffer.baseAddress, buffer.count, &contains)
        }
        return status == 0 ? contains != 0 : true
    }

    func export() throws -> Data {
        var output = HpCoreBuffer(ptr: nil, len: 0)
        guard hp_domain_index_export(pointer, &output) == 0, let bytes = output.ptr else {
            throw PortableDomainListError.invalidData
        }
        defer { hp_core_free(output) }
        return Data(bytes: bytes, count: output.len)
    }
}

struct PortableDomainList: Equatable, Sendable {
    static let maximumBytes = 32 * 1024 * 1024
    static let maximumSupplementBytes = 1024 * 1024

    enum Format: Equatable, Sendable {
        case blockListProject(minimumCount: Int)
        case hardPauseSupplement(category: String)

        fileprivate var kind: UInt32 {
            switch self {
            case .blockListProject: HP_DOMAIN_FORMAT_BLOCK_LIST_PROJECT
            case .hardPauseSupplement: HP_DOMAIN_FORMAT_HARD_PAUSE_SUPPLEMENT
            }
        }
        fileprivate var minimumCount: Int {
            if case .blockListProject(let count) = self { return count }
            return 0
        }
        fileprivate var category: String {
            if case .hardPauseSupplement(let category) = self { return category }
            return ""
        }
    }

    private struct Parsed: Decodable {
        let domains: [String]
        let skippedEntries: Int
        let metadata: [String: String]
    }

    let domains: Set<String>
    let skippedEntries: Int
    let metadata: [String: String]
    private let index: PortableDomainIndex

    init(data: Data, format: Format) throws {
        guard format.minimumCount >= 0 else { throw PortableDomainListError.invalidData }
        do {
            let index = try PortableDomainIndex(data: data, format: format)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let parsed = try decoder.decode(Parsed.self, from: index.export())
            domains = Set(parsed.domains)
            skippedEntries = parsed.skippedEntries
            metadata = parsed.metadata
            self.index = index
        } catch {
            throw PortableDomainListError.invalidData
        }
    }

    func contains(canonicalASCIIHost host: String) -> Bool { index.contains(host) }

    static func == (lhs: PortableDomainList, rhs: PortableDomainList) -> Bool {
        lhs.domains == rhs.domains && lhs.skippedEntries == rhs.skippedEntries
            && lhs.metadata == rhs.metadata
    }
}
