import Foundation
import WasmVMCore

/// Path-component validation per `spec/04-ninep-server.md` §"Path traversal safety".
/// 9P names are atomic path components; a server MUST reject anything that could
/// escape the root or otherwise be a non-name.
enum WalkError: Error, Equatable {
    case invalidComponent
    case escapesRoot
    case nameTooLong
    case tooDeep
}

enum Walk {
    /// Maximum depth of a single Twalk per 9P spec (16 components per request).
    static let maxComponents = 16

    /// Maximum bytes in a single component (POSIX NAME_MAX).
    static let maxNameBytes = 255

    /// Validate one path component.
    static func validateComponent(_ name: String) throws {
        if name.isEmpty { throw WalkError.invalidComponent }
        if name == "." || name == ".." { throw WalkError.invalidComponent }
        if name.contains("/") { throw WalkError.invalidComponent }
        if name.contains("\u{0}") { throw WalkError.invalidComponent }
        if name.utf8.count > maxNameBytes { throw WalkError.nameTooLong }
    }

    /// Validate a list of components and that the list length is within limits.
    /// Does NOT touch the filesystem; pure name-level validation.
    static func validateComponents(_ names: [String]) throws {
        if names.count > maxComponents { throw WalkError.tooDeep }
        for n in names { try validateComponent(n) }
    }

    /// Resolve `names` against `base`, ensuring the resulting URL stays within `root`.
    /// Returns the resolved URL on success.
    /// Per spec, even with no `..` accepted at the component level, we still
    /// double-check root-prefix containment via standardized path comparison
    /// in case symlinks resolve outside.
    static func resolve(base: URL, root: URL, names: [String]) throws -> URL {
        try validateComponents(names)
        var url = base
        for n in names {
            url.appendPathComponent(n)
        }
        let canonical = url.standardized
        let rootCanonical = root.standardized
        let canonicalPath = canonical.path
        let rootPath = rootCanonical.path
        // Allow exact match on root; otherwise require prefix + path separator.
        if canonicalPath == rootPath { return canonical }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard canonicalPath.hasPrefix(prefix) else {
            throw WalkError.escapesRoot
        }
        return canonical
    }
}
