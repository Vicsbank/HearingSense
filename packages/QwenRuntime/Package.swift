// swift-tools-version: 6.2
// QwenRuntime (Window 9): Qwen3.5-4B (MLX, 4-bit) as Hearing Sense's primary summarization engine.
//
// A separate package so that HearingSenseKit — and every `swift test` of it — stays free of MLX
// (which needs the Metal toolchain to build). The app links `QwenRuntime`; everything that is
// not the model itself (prompts' parsing, the engine abstraction, fallback, checks) lives in
// HearingSenseKit and is tested there.
//
// Pinned runtime: mlx-swift-lm 3.32.3 (Qwen3.5 architecture "qwen3_5" is implemented in
// MLXLLM/Models/Qwen35.swift), mlx-swift 0.32.3, swift-transformers (tokenizer + chat template).
import PackageDescription

let package = Package(
    name: "QwenRuntime",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "QwenRuntime", targets: ["QwenRuntime"]),
        .executable(name: "hs-qwen-probe", targets: ["QwenProbe"]),
    ],
    dependencies: [
        .package(path: "../HearingSenseKit"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "QwenRuntime",
            dependencies: [
                .product(name: "ConversationUnderstanding", package: "HearingSenseKit"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]),
        .executableTarget(
            name: "QwenProbe", dependencies: ["QwenRuntime", .product(name: "ConversationUnderstanding", package: "HearingSenseKit")],
            path: "Sources/hs-qwen-probe"),
        .testTarget(name: "QwenRuntimeTests", dependencies: ["QwenRuntime"]),
    ]
)
