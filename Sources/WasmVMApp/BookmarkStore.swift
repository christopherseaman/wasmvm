import Foundation

/// Persists security-scoped folder access across app launches.
public protocol BookmarkStore {
    func save(url: URL, key: String) throws
    /// Returns the resolved URL and a `wasStale` flag. Callers must re-prompt
    /// when stale and immediately call `save` again with the freshly-picked URL.
    func load(key: String) throws -> (url: URL, wasStale: Bool)?
    func clear(key: String)
}

public enum BookmarkStoreError: Error {
    case bookmarkUnavailable
}

public final class UserDefaultsBookmarkStore: BookmarkStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func save(url: URL, key: String) throws {
        // .minimalBookmark is correct for iOS document-picker URLs; .withSecurityScope
        // is macOS-only. Source URL is already security-scoped via the file importer.
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(options: .minimalBookmark,
                                        includingResourceValuesForKeys: nil,
                                        relativeTo: nil)
        defaults.set(data, forKey: key)
    }

    public func load(key: String) throws -> (url: URL, wasStale: Bool)? {
        guard let data = defaults.data(forKey: key) else { return nil }
        var stale = false
        let url = try URL(resolvingBookmarkData: data,
                          options: [],
                          relativeTo: nil,
                          bookmarkDataIsStale: &stale)
        return (url, stale)
    }

    public func clear(key: String) {
        defaults.removeObject(forKey: key)
    }
}
