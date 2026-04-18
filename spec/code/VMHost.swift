import SwiftUI
import WebKit
import UniformTypeIdentifiers

/// Top-level coordinator. Owns both WS servers and the WKWebView.
@MainActor
final class VMHost: ObservableObject {
    private var netServer: LocalWSServer?
    private var fsServer: LocalWSServer?
    @Published var sharedFolder: URL?

    func start() throws {
        netServer = try LocalWSServer(port: 8080, path: "/net") { conn in
            _ = NetBridge(ws: conn)
        }
        netServer?.start()

        fsServer = try LocalWSServer(port: 8081, path: "/9p") { [weak self] conn in
            // Capture sharedFolder at connect time. If user hasn't picked one,
            // fall back to the app's Documents directory.
            let root = self?.sharedFolder
                ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            _ = NinePServer(ws: conn, root: root)
        }
        fsServer?.start()
    }
}

struct ContentView: View {
    @StateObject private var host = VMHost()
    @State private var showPicker = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Pick shared folder") { showPicker = true }
                Spacer()
                Text(host.sharedFolder?.lastPathComponent ?? "no folder")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)

            WebVMView()  // wraps WKWebView pointing at your bundled WebVM HTML
        }
        .onAppear { try? host.start() }
        .fileImporter(isPresented: $showPicker,
                      allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                host.sharedFolder = url
                // The URL is security-scoped; NinePServer calls
                // startAccessingSecurityScopedResource() in its init.
            }
        }
    }
}

struct WebVMView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        // CheerpX needs SharedArrayBuffer. WKWebView in iOS 17+ honors COOP/COEP
        // when served from local resources via WKURLSchemeHandler.
        cfg.limitsNavigationsToAppBoundDomains = true
        let wv = WKWebView(frame: .zero, configuration: cfg)
        // Load your bundled WebVM index.html. Patched CheerpX init points at:
        //   ws://127.0.0.1:8080/net  and  ws://127.0.0.1:8081/9p
        if let url = Bundle.main.url(forResource: "index", withExtension: "html",
                                     subdirectory: "webvm") {
            wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return wv
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
