import Foundation

/// Only positive URL hashes and their expiry times leave memory. No raw URLs,
/// page contents, negative results, or request history are stored or uploaded.
@MainActor
final class AdultRatingStore {
    private let file: URL
    private var cache: AdultRatingCache
    private var lastPruned = Date()
    private(set) var saveFailed = false

    init(file: URL? = nil) {
        self.file =
            file
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HardPause/PrivateRatings/ratings-v1.json")
        let size = (try? self.file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        cache = AdultRatingCache(data: size <= 512 * 1_024 ? try? Data(contentsOf: self.file) : nil)
        if FileManager.default.fileExists(atPath: self.file.path) { persist() }
    }

    func contains(_ url: URL) -> Bool { cache.contains(url) }

    func pruneIfNeeded() {
        guard Date().timeIntervalSince(lastPruned) >= 3_600 else { return }
        lastPruned = Date()
        if FileManager.default.fileExists(atPath: file.path) { persist() }
    }

    func record(_ url: URL) {
        guard !cache.contains(url) else { return }
        cache.record(url)
        persist()
    }

    private func persist() {
        do {
            let directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try cache.encoded().write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            saveFailed = false
        } catch { saveFailed = true }
    }
}
