import Foundation

/// Interprets a route snapshot against the project's target configuration:
/// environment captured by the iPhone microphone while media plays on Bluetooth headphones
/// over the high-quality A2DP (or LE audio) profile.
///
/// This only reflects what iOS *reports*. Whether media audio actually sounds unchanged must
/// still be confirmed by listening on a physical device.
public struct RouteAssessment: Sendable, Equatable {
    public enum Verdict: String, Sendable, Equatable {
        /// Built-in mic in, Bluetooth A2DP/LE out. The configuration this project targets.
        case targetRoute
        /// Built-in mic in, but output is speaker/receiver/wired/etc.
        case builtInMicWithoutBluetoothOutput
        /// Bluetooth microphone over HFP: all Bluetooth audio is expected to drop to call quality.
        case bluetoothHFPInput
        /// Bluetooth microphone with iOS 26 high-quality recording enabled.
        case bluetoothHighQualityInput
        /// No input port in the current route.
        case noInput
        /// Any other input (wired headset, USB, continuity microphone, ...).
        case otherInput
    }

    public var verdict: Verdict
    public var headline: String
    public var detail: String

    public static func evaluate(_ snapshot: AudioRouteSnapshot) -> RouteAssessment {
        let outputNames = snapshot.outputs.map(\.name).joined(separator: ", ")
        guard let input = snapshot.inputs.first else {
            return RouteAssessment(
                verdict: .noInput, headline: "No active input",
                detail: snapshot.isInputAvailable
                    ? "An input is available but the session is not routing it. Start listening to activate it."
                    : "iOS reports no available input route.")
        }

        if input.highQualityRecording?.isEnabled == true {
            return RouteAssessment(
                verdict: .bluetoothHighQualityInput, headline: "Bluetooth mic, high-quality mode",
                detail: "\(input.name) is recording with high-quality Bluetooth enabled. "
                    + "Listen for any change in media quality and latency.")
        }

        switch input.kind {
        case .bluetoothHFP:
            return RouteAssessment(
                verdict: .bluetoothHFPInput, headline: "Bluetooth mic over HFP",
                detail: "\(input.name) is in hands-free mode. Expect call-quality audio for all output "
                    + "while listening.")
        case .builtInMic:
            if snapshot.outputs.contains(where: { $0.kind == .bluetoothA2DP || $0.kind == .bluetoothLE }) {
                return RouteAssessment(
                    verdict: .targetRoute, headline: "Target route",
                    detail: "iPhone microphone in, \(outputNames) out. Confirm by ear that media quality is unchanged.")
            }
            return RouteAssessment(
                verdict: .builtInMicWithoutBluetoothOutput, headline: "iPhone mic, no Bluetooth output",
                detail: "Output is \(outputNames.isEmpty ? "unknown" : outputNames). Connect AirPods to test the target route.")
        default:
            return RouteAssessment(
                verdict: .otherInput, headline: "Other input: \(input.kind.displayName)",
                detail: "Input \(input.name), output \(outputNames.isEmpty ? "unknown" : outputNames).")
        }
    }
}
