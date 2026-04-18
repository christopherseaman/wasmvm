import XCTest
@testable import WasmVMNineP

final class ReaddirCursorTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ninep-readdir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func test_snapshot_excludes_dot_and_dotdot() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("a"))
        try Data().write(to: dir.appendingPathComponent("b"))

        let cursor = try ReaddirCursor.snapshot(of: dir)
        XCTAssertFalse(cursor.entries.contains("."))
        XCTAssertFalse(cursor.entries.contains(".."))
        XCTAssertEqual(Set(cursor.entries), ["a", "b"])
    }

    func test_snapshot_is_sorted() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for n in ["zzz", "aaa", "mmm", "bbb"] {
            try Data().write(to: dir.appendingPathComponent(n))
        }
        let cursor = try ReaddirCursor.snapshot(of: dir)
        XCTAssertEqual(cursor.entries, ["aaa", "bbb", "mmm", "zzz"])
    }

    func test_snapshot_does_not_observe_later_additions() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("first"))

        let cursor = try ReaddirCursor.snapshot(of: dir)
        // Now add a file *after* snapshot. The cursor must not see it.
        try Data().write(to: dir.appendingPathComponent("second"))

        XCTAssertEqual(cursor.entries, ["first"])
    }

    func test_snapshot_empty_dir() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cursor = try ReaddirCursor.snapshot(of: dir)
        XCTAssertEqual(cursor.entries, [])
    }

    func test_snapshot_missing_dir_throws() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nope-\(UUID().uuidString)")
        XCTAssertThrowsError(try ReaddirCursor.snapshot(of: dir))
    }
}
