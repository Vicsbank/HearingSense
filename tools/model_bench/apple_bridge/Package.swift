// swift-tools-version: 6.0
import PackageDescription

// The Apple side of the local model benchmark: a line-based bridge to SystemLanguageModel.default.
let package = Package(
    name: "apple-bridge",
    platforms: [.macOS("27.0")],
    targets: [.executableTarget(name: "apple-bridge", swiftSettings: [.swiftLanguageMode(.v5)])]
)
