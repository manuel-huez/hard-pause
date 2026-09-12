import Foundation
import XCTest

final class PausePageAssetsTests: XCTestCase {
    private let assets = PausePageAssets(files: [
        "/BlockedPage/index.html": .init(data: Data("<h1>Paused</h1>".utf8), contentType: "text/html; charset=utf-8")
    ])

    private func response(path: String, method: String = "GET", host: String = "127.0.0.1:12345") -> String {
        let request = "\(method) \(path) HTTP/1.1\r\nHost: \(host)\r\n\r\n"
        return String(decoding: assets.response(to: Data(request.utf8), port: 12345), as: UTF8.self)
    }

    func testBundledAssetHasValidHeadersAndBody() {
        let value = response(path: "/BlockedPage/index.html")
        XCTAssertTrue(value.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(value.contains("\r\n\r\n<h1>Paused</h1>"))
        XCTAssertTrue(value.contains("frame-ancestors 'none'"))
    }

    func testOnlyExactAssetsAreServed() {
        for path in [
            "/etc/passwd", "/../Recursive.ttf", "/%2e%2e/etc/passwd", "/BlockedPage/index.html?file=/etc/passwd",
        ] {
            XCTAssertTrue(response(path: path).hasPrefix("HTTP/1.1 404"), path)
        }
    }

    func testOtherHostsAndMethodsAreRejected() {
        XCTAssertTrue(response(path: "/BlockedPage/index.html", host: "evil.example:12345").hasPrefix("HTTP/1.1 403"))
        XCTAssertTrue(response(path: "/BlockedPage/index.html", method: "POST").hasPrefix("HTTP/1.1 405"))
    }

    func testHeadHasNoBody() {
        let value = response(path: "/BlockedPage/index.html", method: "HEAD")
        XCTAssertTrue(value.hasPrefix("HTTP/1.1 200"))
        XCTAssertTrue(value.hasSuffix("\r\n\r\n"))
        XCTAssertFalse(value.contains("<h1>"))
    }
}
