import Foundation

/// Per-FID state held by NinePServer per `spec/04-ninep-server.md` §"FID lifecycle".
struct Fid {
    var url: URL
    var handle: FileHandle?
    var isDir: Bool
    var dirCursor: ReaddirCursor?
}

/// Thread-safe FID table.
final class FidTable {
    static let capacity = 4096

    private var fids: [UInt32: Fid] = [:]
    private let lock = NSLock()

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return fids.count
    }

    /// Return a snapshot copy.
    func get(_ id: UInt32) -> Fid? {
        lock.lock(); defer { lock.unlock() }
        return fids[id]
    }

    /// Insert / overwrite. Returns false if at capacity and id is new.
    @discardableResult
    func put(_ id: UInt32, _ fid: Fid) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fids[id] == nil && fids.count >= FidTable.capacity { return false }
        fids[id] = fid
        return true
    }

    /// Mutate in-place under the table lock.
    /// Returns false if the id is unknown.
    @discardableResult
    func mutate(_ id: UInt32, _ body: (inout Fid) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var f = fids[id] else { return false }
        body(&f)
        fids[id] = f
        return true
    }

    @discardableResult
    func remove(_ id: UInt32) -> Fid? {
        lock.lock(); defer { lock.unlock() }
        return fids.removeValue(forKey: id)
    }

    /// Drain all entries (for Tversion session reset and shutdown).
    func removeAll() -> [Fid] {
        lock.lock(); defer { lock.unlock() }
        let all = Array(fids.values)
        fids.removeAll()
        return all
    }
}
