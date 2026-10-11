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
// - SpeechPipeline (Window 3): pre-roll ring buffer and on-device transcription
//   (SpeechAnalyzer + SpeechTranscriber).
// - SemanticSummary (Window 3): Apple Foundation Models interpretation of transcripts, summary
//   validation and the non-LLM fallback.
// - SpeechIntelligence (Window 3): event-driven coordinator (speech activity → transcription →
//   interpretation → SpeechSemanticResult).
// - hs-speech-eval (Window 3, macOS tool): forward-only evaluation of the speech pipeline.
// - hs-model-bench (background-recognition research window, macOS tool): scores classifier
//   backends (Apple SoundAnalysis, converted Core ML models) on a common manifest.
// - Attention (Window 4): deterministic attention priority engine (priority assessment,
//   temporal fusion, deduplication, cooldowns, scheduling). Depends on HearingSenseDomain only.
// - AttentionReplay (Window 4): synthetic event builders, scripted scenarios and the replay
//   harness that drive the production engine without a microphone.
// - hs-attention-eval (Window 4, macOS tool): replays the scenarios and reports the metrics.
// - IslandPresentation (Window 5): what the Live Activity shows — SF Symbol catalog for sounds,
//   the ambient icon stream, the pipeline that joins it with the attention engine's intents, and
//   the gate for expansion requests. Depends on HearingSenseDomain only.
// - IslandViews (Window 5): the activity attributes and the SwiftUI pieces of the Dynamic Island
//   and Lock Screen presentations, shared by the app and its widget extension.
//
// Platform-independent logic is tested on the Mac with `swift test`. iOS-only code
// (AVAudioSession) is compiled under `#if os(iOS)` and tested with xcodebuild on an
// iOS Simulator destination.
import PackageDescription

let package = Package(
    name: "HearingSenseKit",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "HearingSenseAudio", targets: ["HearingSenseAudio"]),
        .library(name: "HearingSenseDomain", targets: ["HearingSenseDomain"]),
        .library(name: "SoundEventDetection", targets: ["SoundEventDetection"]),
        .executable(name: "hs-sound-eval", targets: ["SoundEvaluationTool"]),
        .library(name: "SpeechPipeline", targets: ["SpeechPipeline"]),
        .library(name: "SemanticSummary", targets: ["SemanticSummary"]),
        .library(name: "SpeechIntelligence", targets: ["SpeechIntelligence"]),
        .executable(name: "hs-speech-eval", targets: ["SpeechEvaluationTool"]),
        .executable(name: "hs-model-bench", targets: ["ModelBenchmarkTool"]),
        .library(name: "Attention", targets: ["Attention"]),
        .library(name: "AttentionReplay", targets: ["AttentionReplay"]),
        .executable(name: "hs-attention-eval", targets: ["AttentionReplayTool"]),
        .library(name: "IslandPresentation", targets: ["IslandPresentation"]),
        .library(name: "IslandViews", targets: ["IslandViews"]),
    ],
    targets: [
        .target(name: "HearingSenseAudio"),
        .target(name: "HearingSenseDomain"),
        .target(name: "SoundEventDetection", dependencies: ["HearingSenseAudio", "HearingSenseDomain"]),
        .executableTarget(name: "SoundEvaluationTool", dependencies: ["SoundEventDetection", "HearingSenseDomain"]),
        .target(name: "SpeechPipeline", dependencies: ["HearingSenseAudio", "HearingSenseDomain"]),
        .target(name: "SemanticSummary", dependencies: ["HearingSenseDomain"]),
        .target(name: "SpeechIntelligence",
                dependencies: ["HearingSenseAudio", "HearingSenseDomain", "SoundEventDetection", "SpeechPipeline",
                               "SemanticSummary"]),
        .executableTarget(name: "SpeechEvaluationTool",
                          dependencies: ["SpeechIntelligence", "SpeechPipeline", "SemanticSummary", "SoundEventDetection",
                                         "HearingSenseDomain"]),
        .executableTarget(name: "ModelBenchmarkTool", dependencies: ["SoundEventDetection", "HearingSenseDomain"]),
        .target(name: "Attention", dependencies: ["HearingSenseDomain"]),
        .target(name: "IslandPresentation", dependencies: ["HearingSenseDomain"]),
        .target(name: "IslandViews", dependencies: ["IslandPresentation", "HearingSenseDomain"]),
        .target(name: "AttentionReplay",
                dependencies: ["Attention", "HearingSenseDomain", "SoundEventDetection", "IslandPresentation"]),
        .executableTarget(name: "AttentionReplayTool",
                          dependencies: ["AttentionReplay", "Attention", "HearingSenseDomain", "HearingSenseAudio",
                                         "IslandPresentation", "IslandViews", "SoundEventDetection"]),
        .testTarget(name: "HearingSenseAudioTests", dependencies: ["HearingSenseAudio"]),
        .testTarget(name: "AttentionTests",
                    dependencies: ["Attention", "AttentionReplay", "HearingSenseDomain", "SoundEventDetection"]),
        .testTarget(name: "IslandPresentationTests",
                    dependencies: ["IslandPresentation", "IslandViews", "Attention", "AttentionReplay", "HearingSenseDomain",
                                   "SoundEventDetection"]),
        .testTarget(name: "SoundEventDetectionTests", dependencies: ["SoundEventDetection", "HearingSenseDomain"]),
        .testTarget(name: "SpeechPipelineTests", dependencies: ["SpeechPipeline", "HearingSenseAudio", "HearingSenseDomain"]),
        .testTarget(name: "SemanticSummaryTests", dependencies: ["SemanticSummary", "HearingSenseDomain"]),
        .testTarget(name: "SpeechIntelligenceTests",
                    dependencies: ["SpeechIntelligence", "SpeechPipeline", "SemanticSummary", "SoundEventDetection",
                                   "HearingSenseAudio", "HearingSenseDomain"]),
    ]
)
