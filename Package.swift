// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WasmVM",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "WasmVMCore", targets: ["WasmVMCore"]),
        .library(name: "WasmVMNet", targets: ["WasmVMNet"]),
        .library(name: "WasmVMNineP", targets: ["WasmVMNineP"]),
        .library(name: "WasmVMServer", targets: ["WasmVMServer"]),
        .library(name: "WasmVMApp", targets: ["WasmVMApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Building42/Telegraph.git", from: "0.30.0"),
    ],
    targets: [
        // Pure-Swift codecs and shared types. No Network, no UIKit, no WebKit.
        .target(
            name: "WasmVMCore",
            path: "Sources/WasmVMCore"
        ),

        // NetBridge: NWConnection-backed raw-socket-over-WS protocol handler.
        .target(
            name: "WasmVMNet",
            dependencies: ["WasmVMCore"],
            path: "Sources/WasmVMNet"
        ),

        // NinePServer: 9P2000.L server backed by FileHandle + Darwin.stat.
        .target(
            name: "WasmVMNineP",
            dependencies: ["WasmVMCore"],
            path: "Sources/WasmVMNineP"
        ),

        // Telegraph wiring: HTTP asset routes (Range + COOP/COEP) and WS upgrade demux.
        .target(
            name: "WasmVMServer",
            dependencies: [
                "WasmVMCore",
                "WasmVMNet",
                "WasmVMNineP",
                .product(name: "Telegraph", package: "Telegraph"),
            ],
            path: "Sources/WasmVMServer"
        ),

        // SwiftUI shell + VMHost coordinator + BookmarkStore + WKWebView wrapper.
        .target(
            name: "WasmVMApp",
            dependencies: [
                "WasmVMCore",
                "WasmVMServer",
            ],
            path: "Sources/WasmVMApp"
        ),

        // Tests.
        .testTarget(
            name: "WasmVMCoreTests",
            dependencies: ["WasmVMCore"],
            path: "Tests/WasmVMCoreTests"
        ),
        .testTarget(
            name: "WasmVMNetTests",
            dependencies: ["WasmVMNet"],
            path: "Tests/WasmVMNetTests"
        ),
        .testTarget(
            name: "WasmVMNinePTests",
            dependencies: ["WasmVMNineP"],
            path: "Tests/WasmVMNinePTests"
        ),
        .testTarget(
            name: "WasmVMServerTests",
            dependencies: ["WasmVMServer", "WasmVMCore"],
            path: "Tests/WasmVMServerTests"
        ),
    ]
)
