# 02 - iOS Wrapper

## Project structure

```
WebVMApp/
├── WebVMApp.swift              // @main, scene config
├── VMHost.swift                // coordinator, WS server lifecycle
├── LocalWSServer.swift         // Network.framework WS listener
├── NetBridge.swift             // see 03-net-bridge.md
├── NinePServer.swift           // see 04-ninep-server.md
├── WebVMSchemeHandler.swift    // WKURLSchemeHandler for webvm://
├── BookmarkStore.swift         // security-scoped URL persistence
├── ContentView.swift           // SwiftUI shell
├── Resources/
│   ├── webvm/                  // built WebVM HTML/JS/WASM bundle
│   │   ├── index.html
│   │   ├── cheerpx.js
│   │   └── cheerpx.wasm
│   ├── disk/
│   │   └── base.ext2           // base root filesystem image
│   └── datasets/               // optional bundled read-only datasets
└── Info.plist
```

## Info.plist requirements

| Key | Value | Rationale |
|---|---|---|
| `NSLocalNetworkUsageDescription` | "Used for internal VM networking" | Loopback may trigger local-network permission on some iOS versions |
| `UIFileSharingEnabled` | `YES` | Expose Documents directory to Files app |
| `LSSupportsOpeningDocumentsInPlace` | `YES` | Allow in-place folder picking |
| `UIBackgroundModes` | `[]` | No background execution claimed |

## Deployment target

- iOS 17.0 minimum (WKURLSchemeHandler with custom response headers reliable from 17.0)
- iPadOS 17.0 minimum (same)
- Mac Catalyst: not in PoC scope

## WebVMSchemeHandler

Custom `WKURLSchemeHandler` registered for `webvm://` scheme. Responsibilities:

1. Serve HTML/JS/WASM from `Resources/webvm/` with correct MIME types
2. Set COOP/COEP headers on all responses (required for SharedArrayBuffer)
3. Serve `base.ext2` with full HTTP Range request support
4. Serve bundled datasets from `Resources/datasets/` with Range support

### URL routing

| URL | Served from | Notes |
|---|---|---|
| `webvm:///index.html` | `Resources/webvm/index.html` | Entry point |
| `webvm:///cheerpx.js` | `Resources/webvm/cheerpx.js` | Patched CheerpX |
| `webvm:///cheerpx.wasm` | `Resources/webvm/cheerpx.wasm` | Stock or patched WASM |
| `webvm:///disk/base.ext2` | `Resources/disk/base.ext2` | Range-served |
| `webvm:///datasets/<name>.ext2` | `Resources/datasets/<name>.ext2` | Range-served |

### Required response headers

All responses:
```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
Cross-Origin-Resource-Policy: same-origin
```

Disk image responses (in addition):
```
Accept-Ranges: bytes
Content-Type: application/octet-stream
```

If a request has `Range: bytes=N-M` header, return 206 Partial Content with `Content-Range: bytes N-M/total`. Implementation uses `FileHandle.seek(toOffset:)` and `read(upToCount:)`.

## BookmarkStore

```swift
protocol BookmarkStore {
    func save(url: URL, key: String) throws
    func load(key: String) throws -> URL?
    func clear(key: String)
}
```

Implementation uses `URL.bookmarkData(options: .minimalBookmark, ...)` stored in `UserDefaults`. Resolution uses `URL(resolvingBookmarkData:options:relativeTo:bookmarkDataIsStale:)`.

**Staleness handling:** if `isStale` is true on resolution, app must re-request access via `UIDocumentPickerViewController` and re-save.

**Security scope lifecycle:** `startAccessingSecurityScopedResource()` is called once per NinePServer instance at init (see `04-ninep-server.md`). Matching `stopAccessingSecurityScopedResource()` on NinePServer deinit.

## WKWebView configuration

```swift
let cfg = WKWebViewConfiguration()
cfg.setURLSchemeHandler(WebVMSchemeHandler(), forURLScheme: "webvm")

let prefs = WKWebpagePreferences()
prefs.allowsContentJavaScript = true
cfg.defaultWebpagePreferences = prefs

// Enable developer tools in debug builds
#if DEBUG
cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")
#endif

let wv = WKWebView(frame: .zero, configuration: cfg)
wv.isInspectable = true  // requires iOS 16.4+
wv.load(URLRequest(url: URL(string: "webvm:///index.html")!))
```

**Do not use `loadFileURL:allowingReadAccessTo:`** - that path does not reliably set COOP/COEP headers, and SharedArrayBuffer will be unavailable.

## SwiftUI shell

Minimal UI:
- Full-screen WKWebView
- Toolbar: shared folder picker, VM reset, network status
- No tabs, no drawer, no settings panel in PoC

```swift
struct ContentView: View {
    @StateObject var host = VMHost()
    @State var showPicker = false

    var body: some View {
        NavigationStack {
            WebVMView(host: host)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Shared Folder") { showPicker = true }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu("⋯") {
                            Button("Reset VM", role: .destructive, action: host.resetVM)
                        }
                    }
                }
                .fileImporter(isPresented: $showPicker,
                              allowedContentTypes: [.folder]) { result in
                    host.setSharedFolder(result: result)
                }
        }
    }
}
```

## App lifecycle coordination

### Foreground → Background
- Observe `UIApplication.willResignActiveNotification`
- VMHost sends `pause` message to WKWebView via `evaluateJavaScript`
- CheerpX fork exposes `window.webvm.pause()` that halts the x86 execution loop
- WS connections remain; iOS will suspend them but reconnection logic handles it

### Background → Foreground
- Observe `UIApplication.didBecomeActiveNotification`
- VMHost checks WS server state; restarts listeners if cancelled
- Sends `resume` message; CheerpX reconnects both WS endpoints
- If WS reconnect fails, CheerpX re-requests connection state from Swift (see fork notes in `06-cheerpx-fork.md`)

### Termination
- No explicit cleanup needed; IDBDevice persists to WKWebView's WebKit-managed IndexedDB (located in app sandbox)
- File handles closed implicitly via NinePServer deinit

## Storage quotas

WKWebView IndexedDB quota is dynamic on iOS, typically several hundred MB available without prompting. For overlay sizes beyond that, use Direction A (Swift-backed overlay) - see `08-investigation.md`.

## Debugging

- Safari Web Inspector attaches to `isInspectable=true` WKWebView
- NetBridge and NinePServer log framing errors to `os.Logger` subsystem `com.example.webvm`
- Toggle verbose frame logging via build flag `WEBVM_TRACE_FRAMES`
