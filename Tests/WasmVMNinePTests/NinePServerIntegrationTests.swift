import XCTest
@testable import WasmVMNineP
@testable import WasmVMCore

final class NinePServerIntegrationTests: XCTestCase {

    private var root: URL!
    private var pair: NinePPipeSocketPair!
    private var server: NinePServer!
    private var client: NineClient!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ninep-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        pair = NinePPipeSocketPair()
        server = NinePServer(socket: pair.server, root: root)
        client = NineClient(socket: pair.client)
    }

    override func tearDown() {
        pair?.tearDown()
        pair = nil
        server = nil
        client = nil
        if let root = root { try? FileManager.default.removeItem(at: root) }
        root = nil
    }

    // MARK: - Tversion

    func test_tversion_clamps_msize() throws {
        let (m, ver) = try client.tversion(msize: 1_000_000)
        XCTAssertEqual(ver, "9P2000.L")
        XCTAssertEqual(m, NinePServer.msizeCeiling)
    }

    func test_tversion_returns_smaller_when_client_proposes_less() throws {
        let (m, _) = try client.tversion(msize: 4096)
        XCTAssertEqual(m, 4096)
    }

    func test_tversion_clears_prior_fids() throws {
        _ = try client.tversion()
        _ = try client.tattach(fid: 0)
        // After Tversion (session reset), fid 0 should be unknown.
        _ = try client.tversion(msize: 65536)
        XCTAssertThrowsError(try client.tlopen(fid: 0, flags: 0))
    }

    // MARK: - Tattach

    func test_tattach_returns_root_qid() throws {
        _ = try client.tversion()
        let q = try client.tattach(fid: 0)
        XCTAssertEqual(q.kind, .dir)
    }

    // MARK: - Twalk

    func test_twalk_to_existing_file() throws {
        let f = root.appendingPathComponent("hello.txt")
        try Data("world".utf8).write(to: f)
        _ = try client.tversion()
        _ = try client.tattach(fid: 0)
        let qids = try client.twalk(fid: 0, newfid: 1, names: ["hello.txt"])
        XCTAssertEqual(qids.count, 1)
        XCTAssertEqual(qids[0].kind, .file)
    }

    func test_twalk_zero_components_clones_fid() throws {
        _ = try client.tversion()
        _ = try client.tattach(fid: 0)
        let qids = try client.twalk(fid: 0, newfid: 1, names: [])
        XCTAssertEqual(qids.count, 0)
        // newfid is now usable
        let attr = try client.tgetattr(fid: 1)
        XCTAssertEqual(attr.qid.kind, .dir)
    }

    func test_twalk_to_nonexistent_returns_empty_or_error() throws {
        _ = try client.tversion()
        _ = try client.tattach(fid: 0)
        let errno = try client.twalkExpectingError(fid: 0, newfid: 2, names: ["nope"])
        XCTAssertEqual(errno, LinuxErrno.ENOENT.rawValue,
                       "expected ENOENT for first-component miss")
    }

    func test_twalk_rejects_dotdot() throws {
        _ = try client.tversion()
        _ = try client.tattach(fid: 0)
        let errno = try client.twalkExpectingError(fid: 0, newfid: 2, names: [".."])
        XCTAssertEqual(errno, LinuxErrno.EINVAL.rawValue,
                       "expected EINVAL for .. component")
    }

    func test_twalk_rejects_slash_in_component() throws {
        _ = try client.tversion()
        _ = try client.tattach(fid: 0)
        let errno = try client.twalkExpectingError(fid: 0, newfid: 2, names: ["a/b"])
        XCTAssertEqual(errno, LinuxErrno.EINVAL.rawValue)
    }

    func test_twalk_partial_failure_does_not_establish_newfid() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("d"), withIntermediateDirectories: true)
        _ = try client.tversion()
        _ = try client.tattach(fid: 0)
        let qids = try client.twalk(fid: 0, newfid: 5, names: ["d", "missing"])
        XCTAssertEqual(qids.count, 1, "should return prefix qids only")
        // newfid 5 must NOT be established
        XCTAssertThrowsError(try client.tgetattr(fid: 5)) { e in
            XCTAssertEqual((e as? NinePLerror)?.errno, LinuxErrno.EBADF.rawValue)
        }
    }

    // MARK: - Tlopen / Tread / Twrite

    func test_open_read_write_round_trip() throws {
        let f = root.appendingPathComponent("rw.txt")
        try Data("abcdef".utf8).write(to: f)
        _ = try client.tversion()
        _ = try client.tattach(fid: 0)
        _ = try client.twalk(fid: 0, newfid: 1, names: ["rw.txt"])
        _ = try client.tlopen(fid: 1, flags: 2)   // O_RDWR
        let data = try client.tread(fid: 1, offset: 0, count: 100)
        XCTAssertEqual(data, Data("abcdef".utf8))
        // Overwrite at offset 3
        let written = try client.twrite(fid: 1, offset: 3, data: Data("XYZ".utf8))
        XCTAssertEqual(written, 3)
        // Re-read
        let data2 = try client.tread(fid: 1, offset: 0, count: 100)
        XCTAssertEqual(data2, Data("abcXYZ".utf8))
        try client.tclunk(fid: 1)
    }

    // MARK: - Tlcreate

    func test_tlcreate_creates_and_opens_file() throws {
        _ = try client.tversion()
        _ = try client.tattach(fid: 0)
        // Clone root fid → newfid 7
        _ = try client.twalk(fid: 0, newfid: 7, names: [])
        let (qid, _) = try client.tlcreate(fid: 7, name: "newfile.txt",
                                           flags: 0o2 /* O_RDWR */, mode: 0o644, gid: 1000)
        XCTAssertEqual(qid.kind, .file)
        let written = try client.twrite(fid: 7, offset: 0, data: Data("hello".utf8))
        XCTAssertEqual(written, 5)
        try client.tclunk(fid: 7)

        let onDisk = try Data(contentsOf: root.appendingPathComponent("newfile.txt"))
        XCTAssertEqual(onDisk, Data("hello".utf8))
    }

    // MARK: - Tmkdir / Tunlinkat

    func test_tmkdir_creates_directory() throws {
        _ = try client.tversion()
        _ = try client.tattach(fid: 0)
        let qid = try client.tmkdir(dfid: 0, name: "subdir", mode: 0o755, gid: 1000)
        XCTAssertEqual(qid.kind, .dir)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("subdir").path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func test_tunlinkat_removes_file() throws {
        try Data("x".utf8).write(to: root.appendingPathComponent("rmme"))
        _ = try client.tversion()
        _ = try client.tattach(fid: 0)
        try client.tunlinkat(dfid: 0, name: "rmme", flags: 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("rmme").path))
    }

    func test_tunlinkat_with_AT_REMOVEDIR_removes_dir() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sd"), withIntermediateDirectories: true)
        _ = try client.tversion()
        _ = try client.tattach(fid: 0)
        try client.tunlinkat(dfid: 0, name: "sd", flags: 0x200)  // AT_REMOVEDIR
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("sd").path))
    }

    // MARK: - Treaddir

    func test_treaddir_returns_dot_dotdot_then_entries() throws {
        for n in ["a", "b", "c"] {
            try Data().write(to: root.appendingPathComponent(n))
        }
        _ = try client.tversion()
        _ = try client.tattach(fid: 0)
        // Clone fid 0 to fid 1 so we have a directory fid we can open.
        _ = try client.twalk(fid: 0, newfid: 1, names: [])
        _ = try client.tlopen(fid: 1, flags: 0)
        let entries = try client.treaddir(fid: 1, offset: 0, count: 8192)
        let names = entries.map { $0.3 }
        XCTAssertEqual(names.prefix(2).map { $0 }, [".", ".."])
        XCTAssertEqual(Set(names.dropFirst(2)), ["a", "b", "c"])
        try client.tclunk(fid: 1)
    }

    func test_treaddir_paginates_correctly() throws {
        for i in 0..<20 {
            try Data().write(to: root.appendingPathComponent("file\(i)"))
        }
        _ = try client.tversion()
        _ = try client.tattach(fid: 0)
        _ = try client.twalk(fid: 0, newfid: 1, names: [])
        _ = try client.tlopen(fid: 1, flags: 0)

        // Small page size forces multiple Treaddir calls.
        var allNames: [String] = []
        var offset: UInt64 = 0
        while true {
            let entries = try client.treaddir(fid: 1, offset: offset, count: 64)
            if entries.isEmpty { break }
            for e in entries { allNames.append(e.3); offset = e.1 }
        }
        // All 22 entries: . .. + 20 files
        XCTAssertEqual(Set(allNames), Set([".", ".."] + (0..<20).map { "file\($0)" }))
        try client.tclunk(fid: 1)
    }

    // MARK: - Tclunk + reuse

    func test_tclunk_then_reuse_fid_ok() throws {
        try Data("a".utf8).write(to: root.appendingPathComponent("f1"))
        try Data("b".utf8).write(to: root.appendingPathComponent("f2"))
        _ = try client.tversion()
        _ = try client.tattach(fid: 0)
        _ = try client.twalk(fid: 0, newfid: 1, names: ["f1"])
        try client.tclunk(fid: 1)
        // Reuse fid 1 for a different file
        _ = try client.twalk(fid: 0, newfid: 1, names: ["f2"])
        _ = try client.tlopen(fid: 1, flags: 0)
        let data = try client.tread(fid: 1, offset: 0, count: 10)
        XCTAssertEqual(data, Data("b".utf8))
        try client.tclunk(fid: 1)
    }

    // MARK: - Tgetattr

    func test_tgetattr_returns_expected_mode_uid_gid() throws {
        let f = root.appendingPathComponent("g.txt")
        try Data("12345".utf8).write(to: f)
        _ = try client.tversion()
        _ = try client.tattach(fid: 0)
        _ = try client.twalk(fid: 0, newfid: 1, names: ["g.txt"])
        let a = try client.tgetattr(fid: 1)
        XCTAssertEqual(a.qid.kind, .file)
        XCTAssertEqual(a.uid, NinePServer.reportedUID)
        XCTAssertEqual(a.gid, NinePServer.reportedGID)
        XCTAssertEqual(a.size, 5)
        // mode should encode S_IFREG bit
        XCTAssertNotEqual(a.mode & 0o170000, 0)
    }

    // MARK: - Path traversal hard test

    func test_attempt_to_escape_root_via_dotdot_is_rejected() throws {
        // Plant a sentinel outside the root.
        let sentinel = root.deletingLastPathComponent()
            .appendingPathComponent("escape-sentinel-\(UUID().uuidString).txt")
        try Data("SECRET".utf8).write(to: sentinel)
        defer { try? FileManager.default.removeItem(at: sentinel) }

        _ = try client.tversion()
        _ = try client.tattach(fid: 0)
        let errno = try client.twalkExpectingError(
            fid: 0, newfid: 9, names: ["..", sentinel.lastPathComponent])
        XCTAssertEqual(errno, LinuxErrno.EINVAL.rawValue,
                       "must reject .. component before any FS access")
    }

    // MARK: - Tsetattr / Tfsync / Tstatfs

    func test_tsetattr_chmod() throws {
        let f = root.appendingPathComponent("chmod.txt")
        try Data().write(to: f)
        _ = try client.tversion()
        _ = try client.tattach(fid: 0)
        _ = try client.twalk(fid: 0, newfid: 1, names: ["chmod.txt"])
        try client.tsetattr(fid: 1, valid: 0x1, mode: 0o600)
        let attrs = try FileManager.default.attributesOfItem(atPath: f.path)
        let perm = (attrs[.posixPermissions] as? NSNumber)?.uint32Value ?? 0
        XCTAssertEqual(perm & 0o777, 0o600)
    }

    func test_tsetattr_truncate() throws {
        let f = root.appendingPathComponent("trunc.txt")
        try Data("aaaaaaaa".utf8).write(to: f)
        _ = try client.tversion()
        _ = try client.tattach(fid: 0)
        _ = try client.twalk(fid: 0, newfid: 1, names: ["trunc.txt"])
        try client.tsetattr(fid: 1, valid: 0x8, size: 3)
        let data = try Data(contentsOf: f)
        XCTAssertEqual(data, Data("aaa".utf8))
    }

    func test_tfsync_succeeds_on_open_file() throws {
        let f = root.appendingPathComponent("sync.txt")
        try Data().write(to: f)
        _ = try client.tversion()
        _ = try client.tattach(fid: 0)
        _ = try client.twalk(fid: 0, newfid: 1, names: ["sync.txt"])
        _ = try client.tlopen(fid: 1, flags: 2)
        XCTAssertNoThrow(try client.tfsync(fid: 1))
        try client.tclunk(fid: 1)
    }

    func test_tstatfs_returns_data() throws {
        _ = try client.tversion()
        _ = try client.tattach(fid: 0)
        let r = try client.tstatfs(fid: 0)
        XCTAssertEqual(r.op, .Rstatfs)
        // type field at offset 0, magic
        XCTAssertEqual(r.body.readU32LE(at: 0), 0x01021997)
    }
}
