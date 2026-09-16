import Compression
import Foundation

/// Downloads the same public file for everyone. Visited addresses never enter this actor.
actor AdultWebsiteDatabase {
    static let source = URL(string: "https://blocklistproject.github.io/Lists/alt-version/porn-nl.txt")!
    private let bundleURL: URL?
    private let cacheURL: URL
    private var loaded = false
    private var database: AdultDomainDatabase?
    private var lastAttempt = Date.distantPast
    private var refreshTask: Task<Void, Never>?
    private(set) var status = "Loading local adult website list…"

    init(
        bundleURL: URL? = Bundle.main.url(
            forResource: "domains.txt",
            withExtension: "deflate",
            subdirectory: "AdultWebsites"
        ),
        cacheURL: URL? = nil
    ) {
        self.bundleURL = bundleURL
        self.cacheURL =
            cacheURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HardPause/AdultWebsites/domains.txt")
    }

    func current() -> AdultDomainDatabase? {
        if !loaded {
            loaded = true
            if let data = Self.plainData(at: cacheURL), let parsed = try? AdultDomainDatabase(data: data) {
                database = parsed
            } else if let bundleURL, let data = try? Self.decompressedBundle(at: bundleURL),
                let parsed = try? AdultDomainDatabase(data: data)
            {
                database = parsed
            }
            status =
                if let database {
                    "\(database.domains.count.formatted()) domains · local checks"
                } else {
                    "Adult website list unavailable. RTA checks remain available."
                }
        }
        return database
    }

    static func decompressedBundle(at url: URL) throws -> Data {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size <= AdultDomainDatabase.maximumBytes
        else { throw AdultDatabaseError.invalidData }
        return try decompressBundle(Data(contentsOf: url, options: .mappedIfSafe))
    }

    static func decompressBundle(_ compressed: Data) throws -> Data {
        guard !compressed.isEmpty, compressed.count <= AdultDomainDatabase.maximumBytes else {
            throw AdultDatabaseError.invalidData
        }
        var decompressed = Data()
        do {
            let filter = try OutputFilter(.decompress, using: .zlib) { chunk in
                guard let chunk else { return }
                guard chunk.count <= AdultDomainDatabase.maximumBytes - decompressed.count else {
                    throw AdultDatabaseError.invalidData
                }
                decompressed.append(chunk)
            }
            try filter.write(compressed)
            try filter.finalize()
        } catch {
            throw AdultDatabaseError.invalidData
        }
        guard !decompressed.isEmpty else { throw AdultDatabaseError.invalidData }
        return decompressed
    }

    func refreshIfNeeded(force: Bool = false) {
        _ = current()
        guard refreshTask == nil, force || Date().timeIntervalSince(lastAttempt) >= 3_600 else { return }
        let modified = (try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard force || modified == nil || Date().timeIntervalSince(modified!) >= 86_400 else { return }
        lastAttempt = Date()
        status =
            database == nil ? "Downloading adult website list…" : "Updating website list · local checks remain active"
        refreshTask = Task { await refresh() }
    }

    func install(data: Data) throws {
        let next = try AdultDomainDatabase(data: data)
        if let database, next.domains.count < database.domains.count * 4 / 5 {
            throw AdultDatabaseError.invalidData
        }
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: cacheURL, options: .atomic)
        database = next
        status =
            "\(next.domains.count.formatted()) domains · updated \(Date().formatted(date: .abbreviated, time: .omitted))"
    }

    private func refresh() async {
        defer { refreshTask = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(
            configuration: configuration, delegate: AdultDatabaseRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(from: Self.source)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                response.url == Self.source, response.expectedContentLength <= AdultDomainDatabase.maximumBytes
            else { throw AdultDatabaseError.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                guard data.count < AdultDomainDatabase.maximumBytes else { throw AdultDatabaseError.invalidData }
                data.append(byte)
            }
            try install(data: data)
        } catch {
            status =
                database == nil
                ? "Adult website list unavailable. RTA checks remain available."
                : "\(database!.domains.count.formatted()) domains · update failed; using saved list"
        }
    }

    private static func plainData(at url: URL) -> Data? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size <= AdultDomainDatabase.maximumBytes
        else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }
}

private final class AdultDatabaseRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
