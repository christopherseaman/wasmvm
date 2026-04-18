import Foundation
import Telegraph

/// Cross-Origin Isolation header constants required by spec/02 §"Required response headers".
/// Without all three, WKWebView refuses to expose `SharedArrayBuffer`, which CheerpX requires.
public enum COIHeaders {
    public static let opener = "Cross-Origin-Opener-Policy"
    public static let openerValue = "same-origin"

    public static let embedder = "Cross-Origin-Embedder-Policy"
    public static let embedderValue = "require-corp"

    public static let resource = "Cross-Origin-Resource-Policy"
    public static let resourceValue = "same-origin"

    /// Apply COOP/COEP/CORP to a response. Mutates in place.
    /// Telegraph's `HTTPHeaderName.init(_:)` is module-internal, but the type
    /// is `ExpressibleByStringLiteral` and the headers dictionary has a
    /// `subscript(key: String)` extension, so we use string keys directly.
    public static func apply(to response: HTTPResponse) {
        response.headers[opener] = openerValue
        response.headers[embedder] = embedderValue
        response.headers[resource] = resourceValue
    }
}
