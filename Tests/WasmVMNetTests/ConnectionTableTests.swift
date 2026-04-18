import XCTest
@testable import WasmVMNet

final class ConnectionTableTests: XCTestCase {

    func test_insert_and_lookup() {
        let t = ConnectionTable()
        XCTAssertTrue(t.insert(id: 1, fd: 100))
        XCTAssertEqual(t.fd(for: 1), 100)
        XCTAssertNil(t.fd(for: 2))
        XCTAssertEqual(t.count, 1)
    }

    func test_insert_rejects_duplicate_id() {
        let t = ConnectionTable()
        XCTAssertTrue(t.insert(id: 1, fd: 100))
        XCTAssertFalse(t.insert(id: 1, fd: 200))
        XCTAssertEqual(t.fd(for: 1), 100)
    }

    func test_insert_enforces_capacity_cap() {
        let t = ConnectionTable()
        for i in 0..<UInt32(ConnectionTable.capacity) {
            XCTAssertTrue(t.insert(id: i, fd: Int32(i + 100)))
        }
        XCTAssertFalse(t.insert(id: UInt32(ConnectionTable.capacity), fd: 999))
        XCTAssertEqual(t.count, ConnectionTable.capacity)
    }

    func test_remove_returns_entry() {
        let t = ConnectionTable()
        _ = t.insert(id: 5, fd: 42)
        let e = t.remove(id: 5)
        XCTAssertEqual(e?.fd, 42)
        XCTAssertNil(t.fd(for: 5))
    }

    func test_mark_host_sent_close_is_idempotent() {
        let t = ConnectionTable()
        _ = t.insert(id: 7, fd: 9)
        XCTAssertTrue(t.markHostSentCloseIfNeeded(id: 7))
        XCTAssertFalse(t.markHostSentCloseIfNeeded(id: 7))
        XCTAssertFalse(t.markHostSentCloseIfNeeded(id: 7))
    }

    func test_mark_host_sent_close_unknown_id_returns_false() {
        let t = ConnectionTable()
        XCTAssertFalse(t.markHostSentCloseIfNeeded(id: 99))
    }

    func test_remove_all_returns_all_entries() {
        let t = ConnectionTable()
        _ = t.insert(id: 1, fd: 10)
        _ = t.insert(id: 2, fd: 20)
        _ = t.insert(id: 3, fd: 30)
        let all = t.removeAll()
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(t.count, 0)
    }

    func test_concurrent_inserts_are_safe() {
        let t = ConnectionTable()
        let g = DispatchGroup()
        let q = DispatchQueue(label: "ct.test", attributes: .concurrent)
        for i in 0..<200 {
            g.enter()
            q.async {
                _ = t.insert(id: UInt32(i), fd: Int32(i))
                g.leave()
            }
        }
        g.wait()
        XCTAssertLessThanOrEqual(t.count, ConnectionTable.capacity)
    }
}
