// swift-tools-version: 6.0
// HearingSenseKit — reusable, testable modules for the Hearing Sense iOS 2.0 app.
//
// Window 1 ships one module, HearingSenseAudio (microphone capture, audio-session
// policies, route diagnostics). Later windows add their own modules here; see
// docs/IOS_ARCHITECTURE.md for the planned module map and ownership.
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
    ],
    targets: [
        .target(name: "HearingSenseAudio"),
        .testTarget(name: "HearingSenseAudioTests", dependencies: ["HearingSenseAudio"]),
    ]
)
