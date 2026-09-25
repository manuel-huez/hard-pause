import CryptoKit
import Foundation
import Sparkle

struct ServiceFirstUpdate {
    let build: UInt64
    let archiveURL: URL
    let signature: Data
    let length: UInt64

    enum Failure: LocalizedError {
        case invalidFeed
        case invalidArchive
        case serviceDidNotUpdate

        var errorDescription: String? {
            switch self {
            case .invalidFeed: "The signed update feed is invalid."
            case .invalidArchive: "The downloaded update did not pass signature checks."
            case .serviceDidNotUpdate: "Protection did not finish updating. The app was not replaced."
            }
        }
    }

    static func latest() async throws -> Self {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            let url = URL(string: feed), url.scheme == "https"
        else { throw Failure.invalidFeed }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard data.count <= 256 * 1_024 else { throw Failure.invalidFeed }
        let document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        let items = try document.nodes(forXPath: "/rss/channel/item")
        guard items.count == 1,
            let buildText = try items[0].nodes(forXPath: "*[local-name()='version']").first?.stringValue,
            let build = UInt64(buildText), build > 0,
            let enclosure = try items[0].nodes(forXPath: "enclosure").first as? XMLElement,
            let urlText = enclosure.attribute(forName: "url")?.stringValue,
            let archiveURL = URL(string: urlText),
            archiveURL.scheme == "https",
            archiveURL.host == "github.com",
            archiveURL.path.hasPrefix("/manuel-huez/hard-pause/releases/download/"),
            archiveURL.lastPathComponent == "HardPause-macOS.zip",
            let signatureText = enclosure.attribute(forName: "sparkle:edSignature")?.stringValue,
            let signature = Data(base64Encoded: signatureText), signature.count == 64,
            let lengthText = enclosure.attribute(forName: "length")?.stringValue,
            let length = UInt64(lengthText), length > 0, length <= 256 * 1_024 * 1_024
        else { throw Failure.invalidFeed }
        return Self(build: build, archiveURL: archiveURL, signature: signature, length: length)
    }

    func matches(_ item: SUAppcastItem) -> Bool {
        let enclosure = item.propertiesDictionary["enclosure"] as? [String: String]
        return UInt64(item.versionString) == build
            && item.fileURL == archiveURL
            && item.contentLength == length
            && Data(base64Encoded: enclosure?["sparkle:edSignature"] ?? "") == signature
    }

    func verifiedBundle() async throws -> (bundle: URL, directory: URL) {
        let (archive, _) = try await URLSession.shared.download(from: archiveURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
        guard (attributes[.size] as? NSNumber)?.uint64Value == length,
            let keyText = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            let keyData = Data(base64Encoded: keyText),
            let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { throw Failure.invalidArchive }
        let contents = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard publicKey.isValidSignature(signature, for: contents) else {
            throw Failure.invalidArchive
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hard-pause-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            let output = try await Task.detached(priority: .utility) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                process.arguments = ["-x", "-k", archive.path, directory.path]
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus
            }.value
            let bundle = directory.appendingPathComponent("HardPause.app", isDirectory: true)
            guard output == 0,
                let info = Bundle(url: bundle),
                info.bundleIdentifier == "org.hardpause.app",
                UInt64(info.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") == build
            else { throw Failure.invalidArchive }
            return (bundle, directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
