#if canImport(SwiftUI) && (os(iOS) || os(visionOS))
import SwiftUI
import WasmVMApp

@main
struct WasmVMAppEntry: App {
    var body: some Scene {
        WindowGroup {
            // The harness directory is bundled into the app's main bundle as a
            // folder reference (Xcode "Create folder references" — preserves
            // sub-paths needed by the JS module imports under /vendor/cheerpx).
            ContentView(assetRoot: Self.assetRoot)
        }
    }

    static var assetRoot: URL {
        guard let url = Bundle.main.url(forResource: "webvm-harness", withExtension: nil) else {
            fatalError("webvm-harness folder reference missing from app bundle")
        }
        return url
    }
}
#endif
