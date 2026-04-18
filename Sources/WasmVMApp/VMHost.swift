import Foundation
import Combine
import WasmVMServer
import WasmVMCore

/// Coordinator that owns the LocalServer and BookmarkStore.
/// SwiftUI consumes `@Published var sharedFolder` via `@StateObject`.
@MainActor
public final class VMHost: ObservableObject {
    public static let bookmarkKey = "com.wasmvm.sharedFolderBookmark"

    @Published public private(set) var sharedFolder: URL?
    @Published public private(set) var serverPort: UInt16 = 0
    @Published public private(set) var lastError: String?

    public let bookmarks: BookmarkStore
    public let assetRoot: URL

    /// Boxed reference so the LocalServer's closure can read the latest value
    /// without holding a strong VMHost reference (avoids retain cycle).
    private final class Box { var url: URL? }
    private let folderBox = Box()
    private var server: LocalServer!

    public init(assetRoot: URL,
                bookmarks: BookmarkStore = UserDefaultsBookmarkStore()) {
        self.assetRoot = assetRoot
        self.bookmarks = bookmarks
        let box = self.folderBox
        self.server = LocalServer(
            assetRoot: { assetRoot },
            nineRoot:  { box.url }
        )
        // Restore prior bookmark, if any. Stale → user must re-pick.
        if let entry = (try? bookmarks.load(key: VMHost.bookmarkKey)) ?? nil, !entry.wasStale {
            self.folderBox.url = entry.url
            self.sharedFolder = entry.url
        }
    }

    public func start() {
        do {
            try server.start()
            self.serverPort = server.port
            Log.app.info("local server listening on 127.0.0.1:\(self.serverPort)")
        } catch {
            self.lastError = "server start failed: \(error.localizedDescription)"
            Log.app.error("server start failed: \(String(describing: error))")
        }
    }

    public func stop() {
        server.stop()
        self.serverPort = 0
    }

    /// Persist the picked folder and update the published property.
    /// Called from the SwiftUI shell's `.fileImporter` result handler.
    public func setSharedFolder(_ url: URL) {
        do {
            try bookmarks.save(url: url, key: VMHost.bookmarkKey)
            self.folderBox.url = url
            self.sharedFolder = url
            Log.app.info("shared folder set: \(url.path)")
        } catch {
            self.lastError = "bookmark save failed: \(error.localizedDescription)"
        }
    }
}
