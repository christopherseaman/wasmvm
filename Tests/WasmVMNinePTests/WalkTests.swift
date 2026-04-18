import XCTest
@testable import WasmVMNineP

final class WalkTests: XCTestCase {

    // MARK: - Component validation

    func test_rejects_dotdot() {
        XCTAssertThrowsError(try Walk.validateComponent("..")) { e in
            XCTAssertEqual(e as? WalkError, .invalidComponent)
        }
    }

    func test_rejects_dot() {
        XCTAssertThrowsError(try Walk.validateComponent(".")) { e in
            XCTAssertEqual(e as? WalkError, .invalidComponent)
        }
    }

    func test_rejects_slash_in_component() {
        XCTAssertThrowsError(try Walk.validateComponent("a/b")) { e in
            XCTAssertEqual(e as? WalkError, .invalidComponent)
        }
    }

    func test_rejects_root_slash() {
        XCTAssertThrowsError(try Walk.validateComponent("/")) { e in
            XCTAssertEqual(e as? WalkError, .invalidComponent)
        }
    }

    func test_rejects_empty() {
        XCTAssertThrowsError(try Walk.validateComponent("")) { e in
            XCTAssertEqual(e as? WalkError, .invalidComponent)
        }
    }

    func test_rejects_null_byte() {
        XCTAssertThrowsError(try Walk.validateComponent("a\u{0}b")) { e in
            XCTAssertEqual(e as? WalkError, .invalidComponent)
        }
    }

    func test_accepts_normal_names() throws {
        for name in ["foo", "foo.txt", "Some File", "α", "🦄", ".hidden", "..foo"] {
            XCTAssertNoThrow(try Walk.validateComponent(name), "rejected \(name)")
        }
    }

    func test_rejects_overlong_name() {
        let longName = String(repeating: "a", count: 256)
        XCTAssertThrowsError(try Walk.validateComponent(longName)) { e in
            XCTAssertEqual(e as? WalkError, .nameTooLong)
        }
    }

    // MARK: - Component list depth

    func test_accepts_16_component_walk() throws {
        let names = (0..<16).map { "d\($0)" }
        XCTAssertNoThrow(try Walk.validateComponents(names))
    }

    func test_rejects_17_component_walk() {
        let names = (0..<17).map { "d\($0)" }
        XCTAssertThrowsError(try Walk.validateComponents(names)) { e in
            XCTAssertEqual(e as? WalkError, .tooDeep)
        }
    }

    // MARK: - Resolution + root containment

    func test_resolve_within_root() throws {
        let root = URL(fileURLWithPath: "/tmp/walk-root")
        let resolved = try Walk.resolve(base: root, root: root, names: ["a", "b", "c"])
        XCTAssertEqual(resolved.path, "/tmp/walk-root/a/b/c")
    }

    func test_resolve_zero_components_is_root() throws {
        let root = URL(fileURLWithPath: "/tmp/walk-root")
        let resolved = try Walk.resolve(base: root, root: root, names: [])
        XCTAssertEqual(resolved.standardized.path, root.standardized.path)
    }

    func test_resolve_rejects_dotdot_at_validation_layer() {
        let root = URL(fileURLWithPath: "/tmp/walk-root")
        XCTAssertThrowsError(try Walk.resolve(base: root, root: root, names: [".."])) { e in
            XCTAssertEqual(e as? WalkError, .invalidComponent)
        }
    }
}
