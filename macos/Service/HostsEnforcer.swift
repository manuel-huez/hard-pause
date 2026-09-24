import Darwin
import Foundation

protocol ManagedTextFile: AnyObject {
    func read() throws -> String
    func write(_ contents: String) throws
}

final class POSIXManagedTextFile: ManagedTextFile {
    private let url: URL
    private let maximumBytes: Int

    init(path: String, maximumBytes: Int = 4 * 1_024 * 1_024) {
        url = URL(fileURLWithPath: path)
        self.maximumBytes = maximumBytes
    }

    func read() throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber, size.intValue > maximumBytes {
            throw ServiceRuntimeError.enforcementFailed("\(url.path) is too large")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func write(_ contents: String) throws {
        guard let data = contents.data(using: .utf8), data.count <= maximumBytes else {
            throw ServiceRuntimeError.enforcementFailed("the managed hosts file is too large")
        }
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".hard-pause-hosts-\(UUID().uuidString)")
        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode_t(0o644)
        )
        guard descriptor >= 0 else {
            throw ServiceRuntimeError.enforcementFailed(String(cString: strerror(errno)))
        }
        var installed = false
        defer {
            _ = Darwin.close(descriptor)
            if !installed { _ = unlink(temporary.path) }
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                guard count > 0 else {
                    throw ServiceRuntimeError.enforcementFailed(String(cString: strerror(errno)))
                }
                offset += count
            }
        }
        guard fsync(descriptor) == 0,
            fchmod(descriptor, 0o644) == 0,
            fchown(descriptor, 0, 0) == 0,
            rename(temporary.path, url.path) == 0
        else {
            throw ServiceRuntimeError.enforcementFailed(String(cString: strerror(errno)))
        }
        installed = true
    }
}

final class HostsEnforcer: HostsRuleEnforcing {
    static let beginMarker = "# BEGIN HARD PAUSE — exact domains managed by org.hardpause.service"
    static let endMarker = "# END HARD PAUSE"
    static let standbyBeginMarker = "# BEGIN HARD PAUSE STANDBY — org.hardpause.service.standby"
    static let standbyEndMarker = "# END HARD PAUSE STANDBY"

    private let file: ManagedTextFile
    private let beginMarker: String
    private let endMarker: String
    private let lockPath: String?

    init(
        file: ManagedTextFile = POSIXManagedTextFile(path: "/etc/hosts"),
        standby: Bool = false,
        lockPath: String? = nil
    ) {
        self.file = file
        beginMarker = standby ? Self.standbyBeginMarker : Self.beginMarker
        endMarker = standby ? Self.standbyEndMarker : Self.endMarker
        self.lockPath = lockPath
    }

    func apply(domains: [String]) throws {
        let normalized = Array(Set(domains)).sorted()
        guard normalized.allSatisfy({ DomainRule.normalize($0) == $0 && !DomainRule.isLiteralIPAddress($0) }) else {
            throw ServiceRuntimeError.enforcementFailed("the hosts rules contain an invalid domain")
        }
        try withFileLock {
            let original = try file.read()
            let next = try replacingOwnedSection(in: original, domains: normalized)
            if next != original { try file.write(next) }
        }
    }

    func replacingOwnedSection(in original: String, domains: [String]) throws -> String {
        let lines = lineRecords(in: original)
        let starts = lines.filter { $0.contents == beginMarker }
        let ends = lines.filter { $0.contents == endMarker }
        guard starts.count <= 1, ends.count <= 1, starts.count == ends.count else {
            throw ServiceRuntimeError.enforcementFailed("the Hard Pause hosts section is malformed")
        }
        let unmanaged: String
        if let start = starts.first, let end = ends.first {
            guard start.fullRange.lowerBound < end.fullRange.lowerBound else {
                throw ServiceRuntimeError.enforcementFailed("the Hard Pause hosts section is malformed")
            }
            unmanaged =
                String(original[..<start.fullRange.lowerBound])
                + String(original[end.fullRange.upperBound...])
        } else {
            unmanaged = original
        }

        let conflicts = conflictingDomains(in: unmanaged, selectedDomains: Set(domains))
        guard conflicts.isEmpty else {
            throw ServiceRuntimeError.enforcementFailed(
                "existing hosts entries conflict with: \(conflicts.sorted().joined(separator: ", "))"
            )
        }
        guard !domains.isEmpty else { return unmanaged }

        let newline = original.contains("\r\n") ? "\r\n" : "\n"
        var result = unmanaged
        if !result.isEmpty, result.utf8.last != 0x0A { result += newline }
        result += beginMarker + newline
        for domain in domains {
            result += "0.0.0.0\t\(domain)" + newline
            result += "::\t\(domain)" + newline
        }
        result += endMarker + newline
        return result
    }

    private func withFileLock<T>(_ operation: () throws -> T) throws -> T {
        guard let lockPath else { return try operation() }
        let descriptor = Darwin.open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw ServiceRuntimeError.enforcementFailed("the hosts update lock cannot be opened")
        }
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
            (info.st_mode & S_IFMT) == S_IFREG,
            info.st_uid == 0,
            (info.st_mode & 0o077) == 0,
            flock(descriptor, LOCK_EX) == 0
        else {
            throw ServiceRuntimeError.enforcementFailed("the hosts update lock is unsafe")
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func conflictingDomains(
        in unmanaged: String,
        selectedDomains: Set<String>
    ) -> Set<String> {
        guard !selectedDomains.isEmpty else { return [] }
        let allowedSinkAddresses: Set<String> = ["0.0.0.0", "::"]
        var conflicts = Set<String>()
        for line in lineRecords(in: unmanaged) {
            let code = line.contents.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let fields = code.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2 else { continue }
            let address = String(fields[0]).lowercased()
            guard !allowedSinkAddresses.contains(address) else { continue }
            for alias in fields.dropFirst() {
                var host = String(alias).lowercased()
                while host.hasSuffix(".") { host.removeLast() }
                if selectedDomains.contains(host) { conflicts.insert(host) }
            }
        }
        return conflicts
    }

    private func lineRecords(in text: String) -> [HostLine] {
        var records: [HostLine] = []
        let bytes = text.utf8
        var byteStart = bytes.startIndex
        while byteStart < bytes.endIndex {
            let lineFeed = bytes[byteStart...].firstIndex(of: 0x0A)
            let byteFullEnd = lineFeed.map { bytes.index(after: $0) } ?? bytes.endIndex
            var byteContentEnd = lineFeed ?? bytes.endIndex
            if byteContentEnd > byteStart {
                let previous = bytes.index(before: byteContentEnd)
                if bytes[previous] == 0x0D { byteContentEnd = previous }
            }
            guard let start = String.Index(byteStart, within: text),
                let fullEnd = String.Index(byteFullEnd, within: text)
            else { break }
            records.append(
                HostLine(
                    contents: String(decoding: bytes[byteStart..<byteContentEnd], as: UTF8.self),
                    fullRange: start..<fullEnd
                )
            )
            byteStart = byteFullEnd
        }
        return records
    }
}

private struct HostLine {
    let contents: String
    let fullRange: Range<String.Index>
}
