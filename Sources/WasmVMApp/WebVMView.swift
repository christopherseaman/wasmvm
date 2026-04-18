#if canImport(SwiftUI) && canImport(WebKit) && (os(iOS) || os(visionOS))
import SwiftUI
import WebKit

/// SwiftUI wrapper around `WKWebView` that loads the local Telegraph URL.
/// Per `spec/02-ios-wrapper.md`, we MUST NOT use `loadFileURL` — that path
/// does not reliably set COOP/COEP, breaking SharedArrayBuffer.
public struct WebVMView: UIViewRepresentable {
    public let port: UInt16

    public init(port: UInt16) { self.port = port }

    public func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        cfg.defaultWebpagePreferences = prefs
        // Developer extras toggle for Safari Web Inspector.
        #if DEBUG
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif

        let wv = WKWebView(frame: .zero, configuration: cfg)
        // iOS 16.4+. Lets Safari Web Inspector attach for crossOriginIsolated check.
        wv.isInspectable = true
        return wv
    }

    public func updateUIView(_ wv: WKWebView, context: Context) {
        guard port != 0 else { return }
        let urlStr = "http://127.0.0.1:\(port)/index.html"
        guard let url = URL(string: urlStr) else { return }
        if wv.url != url {
            wv.load(URLRequest(url: url))
        }
    }
}
#endif
