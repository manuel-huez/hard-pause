import Darwin
import Foundation

/// Called under the repository's file-coordination lock.
enum DurableFile {
    static func write(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).pending")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(
            to: temporary, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard rename(temporary.path, destination.path) == 0 else { throw posixError() }
        try synchronizeDirectory(directory)
    }

    static func remove(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { throw posixError() }
        defer { _ = Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw posixError() }
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
