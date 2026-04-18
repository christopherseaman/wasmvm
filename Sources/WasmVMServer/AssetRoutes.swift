import Foundation
import Telegraph

/// Static-file serving from a document root. Supports `Range` for partial content,
/// applies COOP/COEP/CORP on every response, and chooses `Content-Type` from the
/// path extension. Custom rather than `HTTPFileHandler` because that handler
/// doesn't expose response-header injection.
public final class AssetRoutes {
    private let rootProvider: () -> URL

    public init(rootProvider: @escaping () -> URL) {
        self.rootProvider = rootProvider
    }

    /// Bind `GET /*` to this asset handler. Caller should add this last so any
    /// WS upgrade routes win first.
    public func install(on server: Server) {
        server.route(.GET, regex: "^/.*$") { [weak self] request in
            guard let self = self else { return HTTPResponse(.serviceUnavailable) }
            return self.handle(request: request)
        }
    }

    /// Public for unit testing.
    public func handle(request: HTTPRequest) -> HTTPResponse {
        let path = request.uri.path
        let resolved = resolvePath(path)
        guard let fileURL = resolved else {
            return notFound()
        }

        // Reject paths escaping the root via .. or symlink shenanigans.
        let canonicalRoot = rootProvider().standardized.path
        let canonicalFile = fileURL.standardized.path
        let prefix = canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/"
        if !(canonicalFile == canonicalRoot || canonicalFile.hasPrefix(prefix)) {
            return notFound()
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir) else {
            return notFound()
        }
        if isDir.boolValue {
            return notFound()
        }

        if let rangeStr = request.headers.range, let range = parseByteRange(rangeStr) {
            return rangeResponse(url: fileURL, range: range)
        }
        return fullResponse(url: fileURL)
    }

    // MARK: - Path resolution

    private func resolvePath(_ uriPath: String) -> URL? {
        var rel = uriPath
        if rel.hasPrefix("/") { rel.removeFirst() }
        if rel.isEmpty { rel = "index.html" }
        // Block obvious escape attempts cheaply; full canonicalization happens in handle().
        if rel.contains("..") { return nil }
        let url = rootProvider().appendingPathComponent(rel)
        return url
    }

    // MARK: - Range parsing

    private struct ByteRange {
        let start: UInt64
        let end: UInt64?
    }

    private func parseByteRange(_ s: String) -> ByteRange? {
        guard s.hasPrefix("bytes=") else { return nil }
        let body = s.dropFirst("bytes=".count)
        let parts = body.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        guard let start = UInt64(parts[0]) else { return nil }
        if parts[1].isEmpty {
            return ByteRange(start: start, end: nil)
        }
        guard let end = UInt64(parts[1]) else { return nil }
        return ByteRange(start: start, end: end)
    }

    // MARK: - Response builders

    private func fullResponse(url: URL) -> HTTPResponse {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return notFound()
        }
        let response = HTTPResponse(.ok, body: data)
        response.headers.contentType = mimeType(for: url)
        response.headers.acceptRanges = "bytes"
        COIHeaders.apply(to: response)
        return response
    }

    private func rangeResponse(url: URL, range: ByteRange) -> HTTPResponse {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let total = (attrs[.size] as? NSNumber)?.uint64Value ?? 0

        if total == 0 || range.start >= total {
            let r = HTTPResponse(.rangeNotSatisfiable)
            r.headers.contentRange = "bytes */\(total)"
            COIHeaders.apply(to: r)
            return r
        }
        let endInclusive = min(range.end ?? (total - 1), total - 1)
        if endInclusive < range.start {
            let r = HTTPResponse(.rangeNotSatisfiable)
            r.headers.contentRange = "bytes */\(total)"
            COIHeaders.apply(to: r)
            return r
        }

        let length = Int(endInclusive - range.start + 1)
        let body: Data
        do {
            let fh = try FileHandle(forReadingFrom: url)
            defer { try? fh.close() }
            try fh.seek(toOffset: range.start)
            body = try fh.read(upToCount: length) ?? Data()
        } catch {
            return notFound()
        }

        let response = HTTPResponse(.partialContent, body: body)
        response.headers.contentType = mimeType(for: url)
        response.headers.contentRange = "bytes \(range.start)-\(endInclusive)/\(total)"
        response.headers.acceptRanges = "bytes"
        COIHeaders.apply(to: response)
        return response
    }

    private func notFound() -> HTTPResponse {
        let r = HTTPResponse(.notFound)
        COIHeaders.apply(to: r)
        return r
    }

    // MARK: - MIME

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html", "htm":  return "text/html; charset=utf-8"
        case "js", "mjs":    return "application/javascript"
        case "css":          return "text/css; charset=utf-8"
        case "wasm":         return "application/wasm"
        case "json":         return "application/json"
        case "svg":          return "image/svg+xml"
        case "png":          return "image/png"
        case "jpg", "jpeg":  return "image/jpeg"
        case "ico":          return "image/x-icon"
        case "txt", "md":    return "text/plain; charset=utf-8"
        case "ext2", "img":  return "application/octet-stream"
        default:             return "application/octet-stream"
        }
    }
}
