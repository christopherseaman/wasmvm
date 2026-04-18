import Foundation

/// Snapshot-on-first-read directory cache per `spec/04-ninep-server.md`
/// §"Directory reading semantics".
///
/// 9P.L Treaddir uses opaque server-chosen offsets; we use 1-based array
/// indexes with offset 0 always meaning "synthetic dot/dotdot entries first,
/// then real entries from index 0".
///
/// We intentionally include `.` and `..` as the first two synthetic entries —
/// many Linux 9p clients (and `getdents64`-based code) expect them.
final class ReaddirCursor {
    /// Captured snapshot of names at this cursor's directory.
    let entries: [String]

    init(entries: [String]) {
        self.entries = entries
    }

    /// Build a cursor by enumerating the URL non-recursively.
    /// Excludes `.` / `..` from `entries`; those are emitted as synthetic
    /// offsets 0 and 1 by the server.
    static func snapshot(of url: URL) throws -> ReaddirCursor {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: url.path)
            .filter { $0 != "." && $0 != ".." }
            .sorted()
        return ReaddirCursor(entries: names)
    }
}
