#if canImport(SwiftUI) && (os(iOS) || os(visionOS))
import SwiftUI
import UniformTypeIdentifiers

public struct ContentView: View {
    @StateObject private var host: VMHost
    @State private var showPicker = false

    /// Caller supplies the asset root (folder containing `index.html`). In the
    /// shipping app this is `Bundle.main.url(forResource: "webvm-harness", ...)`.
    public init(assetRoot: URL) {
        _host = StateObject(wrappedValue: VMHost(assetRoot: assetRoot))
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                if host.serverPort != 0 {
                    WebVMView(port: host.serverPort)
                        .ignoresSafeArea()
                } else {
                    ProgressView("Starting local server…")
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Pick Shared Folder") { showPicker = true }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if let f = host.sharedFolder {
                        Text(f.lastPathComponent).font(.caption)
                    } else {
                        Text("No folder").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    host.setSharedFolder(url)
                }
            }
        }
        .onAppear { host.start() }
    }
}
#endif
