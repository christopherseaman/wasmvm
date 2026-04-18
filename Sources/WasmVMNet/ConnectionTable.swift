import Foundation

/// Thread-safe map of connection-id → live POSIX socket fd plus per-connection state.
/// Capacity cap per `spec/03-net-bridge.md` §"Validation" (256 per WS).
final class ConnectionTable {
    static let capacity = 256

    struct Entry {
        let fd: Int32
        /// Set true after the host has emitted CLOSE for this conn so the socket-pump
        /// teardown path doesn't double-send. See `spec/03-net-bridge.md` reference
        /// sketch L93–L108 race for context.
        var hostSentClose: Bool
    }

    private var entries: [UInt32: Entry] = [:]
    private let lock = NSLock()

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    var allFds: [Int32] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.map { $0.fd }
    }

    /// Insert a new connection. Returns false if capacity would be exceeded
    /// or the id is already in use.
    func insert(id: UInt32, fd: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard entries[id] == nil, entries.count < ConnectionTable.capacity else {
            return false
        }
        entries[id] = Entry(fd: fd, hostSentClose: false)
        return true
    }

    func fd(for id: UInt32) -> Int32? {
        lock.lock(); defer { lock.unlock() }
        return entries[id]?.fd
    }

    /// Atomically check-and-set the hostSentClose flag.
    /// Returns true if this caller is the first to mark it (i.e., should send CLOSE);
    /// false if it was already marked.
    func markHostSentCloseIfNeeded(id: UInt32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var e = entries[id] else { return false }
        guard !e.hostSentClose else { return false }
        e.hostSentClose = true
        entries[id] = e
        return true
    }

    /// Remove and return the entry for cleanup.
    @discardableResult
    func remove(id: UInt32) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries.removeValue(forKey: id)
    }

    func removeAll() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        let all = Array(entries.values)
        entries.removeAll()
        return all
    }
}
