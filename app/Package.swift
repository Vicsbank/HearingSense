// swift-tools-version: 6.0
// Hearing Sense — 原生 macOS 应用。只需 Command Line Tools 即可构建（不需要 Xcode）:
//   ./scripts/build_app.sh
import PackageDescription

let package = Package(
    name: "HearingSense",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "HearingSense", targets: ["HearingSense"]),
        .executable(name: "hs-cli", targets: ["hs-cli"]),
    ],
    targets: [
        .target(name: "HearingSenseCore"),
        .executableTarget(name: "HearingSense", dependencies: ["HearingSenseCore"]),
        .executableTarget(name: "hs-cli", dependencies: ["HearingSenseCore"]),
        // 这套 Command Line Tools 没有 XCTest，swift-testing 的宏插件也缺失，所以测试是一个可执行目标
        .executableTarget(name: "hs-selftest", dependencies: ["HearingSenseCore"]),
    ]
)
