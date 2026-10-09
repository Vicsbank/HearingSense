// swift-tools-version: 6.0
// HearingSenseKit — reusable, testable modules for the Hearing Sense iOS 2.0 app.
//
// Modules (see docs/IOS_ARCHITECTURE.md for the module map and ownership):
// - HearingSenseAudio (Window 1): microphone capture, audio-session policies, route diagnostics.
// - HearingSenseDomain (Window 2): shared value types (predictions, categories, acoustic events).
//   Foundation only, so later modules (attention engine, presentation) stay framework-free.
// - SoundEventDetection (Window 2): Apple SoundAnalysis streaming classifier, label taxonomy,
//   confidence filtering and temporal event detection.
// - hs-sound-eval (Window 2, macOS tool): forward-only offline evaluation of the same pipeline
//   on local audio files. No training.
//
// Platform-independent logic is tested on the Mac with `swift test`. iOS-only code
// (AVAudioSession) is compiled under `#if os(iOS)` and tested with xcodebuild on an
// iOS Simulator destination.
import PackageDescription

let package = Package(
    name: "HearingSenseKit",
    platforms: [.iOS("26.0"), .macOS("15.0")],
    products: [
        .library(name: "HearingSenseAudio", targets: ["HearingSenseAudio"]),
        .library(name: "HearingSenseDomain", targets: ["HearingSenseDomain"]),
        .library(name: "SoundEventDetection", targets: ["SoundEventDetection"]),
        .executable(name: "hs-sound-eval", targets: ["SoundEvaluationTool"]),
    ],
    targets: [
        .target(name: "HearingSenseAudio"),
        .target(name: "HearingSenseDomain"),
        .target(name: "SoundEventDetection", dependencies: ["HearingSenseAudio", "HearingSenseDomain"]),
        .executableTarget(name: "SoundEvaluationTool", dependencies: ["SoundEventDetection", "HearingSenseDomain"]),
        .testTarget(name: "HearingSenseAudioTests", dependencies: ["HearingSenseAudio"]),
        .testTarget(name: "SoundEventDetectionTests", dependencies: ["SoundEventDetection", "HearingSenseDomain"]),
    ]
)
