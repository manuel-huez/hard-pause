import Foundation
import Network

/// Serves only the bundled pause-page assets, on IPv4 loopback. It never accepts
/// file paths or a blocked URL from the request and does not record requests.
@MainActor
final class LocalPausePageServer {
    private(set) var pageURL: URL?
    private(set) var failure: String?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "org.hardpause.pause-page")

    func start() {
        guard listener == nil else { return }
        do {
            let assets = try PausePageAssets(bundle: .main)
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let next = try NWListener(using: parameters)
            let connectionQueue = queue
            next.newConnectionHandler = { connection in
                PausePageConnection(connection: connection, assets: assets).start(on: connectionQueue)
            }
            next.stateUpdateHandler = { [weak self, weak next] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = next?.port else { return }
                        self.pageURL = URL(string: "http://127.0.0.1:\(port.rawValue)/BlockedPage/index.html")
                        self.failure = nil
                    case .failed:
                        self.pageURL = nil
                        self.failure = "The local pause page could not start."
                        next?.cancel()
                        self.listener = nil
                    default: break
                    }
                }
            }
            listener = next
            next.start(queue: queue)
        } catch {
            failure = "The local pause page could not start."
        }
    }
}

struct PausePageAssets: Sendable {
    struct Asset: Sendable {
        let data: Data
        let contentType: String
    }
    let files: [String: Asset]

    init(bundle: Bundle) throws {
        guard let root = bundle.resourceURL else { throw CocoaError(.fileNoSuchFile) }
        let types = [
            "BlockedPage/index.html": "text/html; charset=utf-8",
            "BlockedPage/blocked.css": "text/css; charset=utf-8",
            "BlockedPage/blocked.js": "text/javascript; charset=utf-8",
            "mascot/mascot.css": "text/css; charset=utf-8",
            "mascot/mascot.js": "text/javascript; charset=utf-8",
            "Recursive.ttf": "font/ttf",
        ]
        files = try Dictionary(
            uniqueKeysWithValues: types.map { path, type in
                ("/" + path, Asset(data: try Data(contentsOf: root.appendingPathComponent(path)), contentType: type))
            })
    }

    init(files: [String: Asset]) { self.files = files }

    func response(to request: Data, port: UInt16) -> Data {
        guard let text = String(data: request, encoding: .utf8),
            let firstLine = text.components(separatedBy: "\r\n").first
        else {
            return Self.reply(status: "400 Bad Request")
        }
        let parts = firstLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else {
            return Self.reply(status: "400 Bad Request")
        }
        guard parts[0] == "GET" || parts[0] == "HEAD" else {
            return Self.reply(status: "405 Method Not Allowed")
        }
        let hosts = text.components(separatedBy: "\r\n").dropFirst().compactMap { line -> String? in
            guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == "host" else { return nil }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard hosts == ["127.0.0.1:\(port)"] else { return Self.reply(status: "403 Forbidden") }
        // Exact dictionary lookup: no decoding, filesystem traversal, or user-supplied file reads.
        guard let asset = files[String(parts[1])] else { return Self.reply(status: "404 Not Found") }
        return Self.reply(status: "200 OK", asset: asset, headOnly: parts[0] == "HEAD")
    }

    private static func reply(status: String, asset: Asset? = nil, headOnly: Bool = false) -> Data {
        let body = asset?.data ?? Data()
        let headers = """
            HTTP/1.1 \(status)\r
            Content-Type: \(asset?.contentType ?? "text/plain; charset=utf-8")\r
            Content-Length: \(body.count)\r
            Cache-Control: no-store\r
            X-Content-Type-Options: nosniff\r
            Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; font-src 'self'; connect-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'\r
            Connection: close\r
            \r
            """
        var result = Data((headers + "\n").utf8)
        if !headOnly { result.append(body) }
        return result
    }
}

private final class PausePageConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let assets: PausePageAssets
    private var request = Data()

    init(connection: NWConnection, assets: PausePageAssets) {
        self.connection = connection
        self.assets = assets
    }

    func start(on queue: DispatchQueue) {
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) { [connection] in connection.cancel() }
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [self] data, _, complete, error in
            if let data { request.append(data) }
            guard error == nil, request.count <= 8_192 else {
                connection.cancel()
                return
            }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                guard let endpoint = connection.currentPath?.localEndpoint,
                    case .hostPort(_, let port) = endpoint
                else {
                    connection.cancel()
                    return
                }
                let reply = assets.response(to: request, port: port.rawValue)
                connection.send(content: reply, completion: .contentProcessed { [connection] _ in connection.cancel() })
            } else if complete {
                connection.cancel()
            } else {
                receive()
            }
        }
    }
}
