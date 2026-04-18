import XCTest
import Foundation
@testable import WasmVMServer

/// Real Telegraph + real URLSession against a tmpdir document root.
final class AssetRoutesTests: XCTestCase {
    var tmpRoot: URL!
    var server: LocalServer!

    override func setUpWithError() throws {
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wasmvm-asset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        try "<!doctype html><title>ok</title>".data(using: .utf8)!
            .write(to: tmpRoot.appendingPathComponent("index.html"))
        try "console.log(1)".data(using: .utf8)!
            .write(to: tmpRoot.appendingPathComponent("bootstrap.js"))
        try Data(repeating: 0xAB, count: 4096)
            .write(to: tmpRoot.appendingPathComponent("disk-base.ext2"))
        try FileManager.default.createDirectory(
            at: tmpRoot.appendingPathComponent("vendor/cheerpx"),
            withIntermediateDirectories: true
        )
        try Data("WASM!".utf8).write(to: tmpRoot.appendingPathComponent("vendor/cheerpx/cxcore.wasm"))

        server = LocalServer(
            assetRoot: { [tmpRoot] in tmpRoot! },
            nineRoot: { nil }
        )
        try server.start()
    }

    override func tearDown() {
        server?.stop()
        if let r = tmpRoot { try? FileManager.default.removeItem(at: r) }
        super.tearDown()
    }

    private func get(_ path: String,
                     headers: [String: String] = [:],
                     line: UInt = #line) async throws -> (HTTPURLResponse, Data) {
        let url = URL(string: "http://127.0.0.1:\(server.port)\(path)")!
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (resp as! HTTPURLResponse, data)
    }

    func test_index_html_has_coi_headers_and_correct_mime() async throws {
        let (resp, body) = try await get("/index.html")
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertEqual(resp.value(forHTTPHeaderField: "Cross-Origin-Opener-Policy"), "same-origin")
        XCTAssertEqual(resp.value(forHTTPHeaderField: "Cross-Origin-Embedder-Policy"), "require-corp")
        XCTAssertEqual(resp.value(forHTTPHeaderField: "Cross-Origin-Resource-Policy"), "same-origin")
        XCTAssertTrue(resp.value(forHTTPHeaderField: "Content-Type")?.starts(with: "text/html") ?? false)
        XCTAssertEqual(String(data: body, encoding: .utf8), "<!doctype html><title>ok</title>")
    }

    func test_root_path_serves_index() async throws {
        let (resp, _) = try await get("/")
        XCTAssertEqual(resp.statusCode, 200)
    }

    func test_js_mime_and_coi() async throws {
        let (resp, _) = try await get("/bootstrap.js")
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertEqual(resp.value(forHTTPHeaderField: "Content-Type"), "application/javascript")
        XCTAssertEqual(resp.value(forHTTPHeaderField: "Cross-Origin-Embedder-Policy"), "require-corp")
    }

    func test_wasm_mime() async throws {
        let (resp, body) = try await get("/vendor/cheerpx/cxcore.wasm")
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertEqual(resp.value(forHTTPHeaderField: "Content-Type"), "application/wasm")
        XCTAssertEqual(body, Data("WASM!".utf8))
    }

    func test_missing_returns_404() async throws {
        let (resp, _) = try await get("/does-not-exist.bin")
        XCTAssertEqual(resp.statusCode, 404)
        // 404 must still carry COI headers (the harness fetches static assets,
        // not 404s, but the spec says "every asset response").
        XCTAssertEqual(resp.value(forHTTPHeaderField: "Cross-Origin-Embedder-Policy"), "require-corp")
    }

    func test_path_traversal_rejected() async throws {
        let (resp, _) = try await get("/../../etc/passwd")
        XCTAssertEqual(resp.statusCode, 404)
    }

    func test_disk_range_returns_206_with_correct_content_range() async throws {
        let (resp, body) = try await get("/disk-base.ext2",
                                          headers: ["Range": "bytes=10-19"])
        XCTAssertEqual(resp.statusCode, 206)
        XCTAssertEqual(resp.value(forHTTPHeaderField: "Content-Range"), "bytes 10-19/4096")
        XCTAssertEqual(body.count, 10)
        XCTAssertEqual(body, Data(repeating: 0xAB, count: 10))
        XCTAssertEqual(resp.value(forHTTPHeaderField: "Cross-Origin-Embedder-Policy"), "require-corp")
    }

    func test_disk_open_ended_range() async throws {
        let (resp, body) = try await get("/disk-base.ext2",
                                          headers: ["Range": "bytes=4090-"])
        XCTAssertEqual(resp.statusCode, 206)
        XCTAssertEqual(resp.value(forHTTPHeaderField: "Content-Range"), "bytes 4090-4095/4096")
        XCTAssertEqual(body.count, 6)
    }

    func test_full_disk_get_no_range() async throws {
        let (resp, body) = try await get("/disk-base.ext2")
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertEqual(body.count, 4096)
        XCTAssertEqual(resp.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertEqual(resp.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")
    }
}
