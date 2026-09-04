// swift-tools-version: 5.9
import PackageDescription

// Test harness only. XcodeGen remains the application build; no source copies.
let package = Package(
    name: "QuickCueTransport",
    platforms: [.macOS(.v13)],
    products: [.library(name: "QuickCueTransport", targets: ["QuickCueTransport"])],
    targets: [
        .target(
            name: "QuickCueTransport", path: "QuickCue/Core/AI",
            sources: ["SSEDecoder.swift", "SSETransport.swift"]
        ),
        .testTarget(
            name: "QuickCueTransportTests", dependencies: ["QuickCueTransport"],
            path: "TransportTests"
        ),
    ]
)
