#if DEBUG
import ConversationUnderstanding
import Foundation
import HearingSenseAudio

/// The device test mode of Debug builds (Window 8): what this build may do on the iPhone, read
/// from the device's own storage at process start. It therefore also holds for a process that
/// iOS starts for an App Intent (the Action Button), where there are no launch arguments.
///
/// Fail-closed (`DeviceTestConfiguration.resolve`): with nothing stored, or with data that
/// cannot be read, the microphone, speech transcription and model inference are prohibited and
/// every session ends by itself. Launch arguments can only issue the explicit commands of
/// `DeviceTestConfiguration.applying(arguments:)`; the result is stored, so the next launch
/// without arguments runs under the same rules.
///
/// The mode restricts what the app does. It never writes the user's own settings ("Transcribe
/// nearby speech", the Dynamic Island switches): those keep their stored values.
///
/// Release builds do not contain this file.
enum DeviceTestMode {
    private static let key = "debug.deviceTestMode.v1"

    private struct Loaded {
        var configuration: DeviceTestConfiguration
        var origin: DeviceTestConfiguration.Origin
        var notes: [String]
    }

    private static var loaded: Loaded = load()

    static var configuration: DeviceTestConfiguration { loaded.configuration }
    static var origin: DeviceTestConfiguration.Origin { loaded.origin }
    static var summary: String { configuration.summary(origin: origin) }

    private static func load() -> Loaded {
        let defaults = UserDefaults.standard
        let (stored, origin) = DeviceTestConfiguration.resolve(defaults.data(forKey: key))
        var notes: [String] = []
        switch origin {
        case .stored: break
        case .missing: notes.append("nothing was stored: locked configuration written")
        case .unreadable: notes.append("the stored configuration could not be read: locked configuration written")
        }
        let (configuration, commands) = stored.applying(arguments: ProcessInfo.processInfo.arguments)
        notes += commands.map { "launch argument: \($0)" }
        if origin != .stored || configuration != stored { store(configuration) }
        return Loaded(configuration: configuration, origin: origin, notes: notes)
    }

    private static func store(_ configuration: DeviceTestConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        UserDefaults.standard.set(data, forKey: key)
        // The emergency stop has to survive a process that is terminated right afterwards.
        UserDefaults.standard.synchronize()
    }

    /// Emergency stop: stored at once; every start is refused until `resume()`.
    static func halt() {
        loaded.configuration.isHalted = true
        store(loaded.configuration)
    }

    static func resume() {
        loaded.configuration.isHalted = false
        store(loaded.configuration)
    }

    /// Lines for the diagnostics report.
    static func reportLines() -> [String] {
        let configuration = configuration
        var lines = ["Device test mode (Debug builds; stored on this iPhone): \(summary)"]
        guard configuration.isEnabled else { return lines }
        lines.append("  microphone \(configuration.prohibitsMicrophone ? "prohibited: every session is synthetic (no audio session, no engine)" : "allowed for starts a person makes")"
            + "; transcription \(configuration.prohibitsTranscription ? "prohibited (the stored switch is not changed)" : "allowed")"
            + "; model inference \(configuration.prohibitsModelInference ? "prohibited (no language model, no experimental classifier)" : "allowed")")
        lines.append("  every session ends by itself after \(Int(configuration.normalized.sessionLimit)) s; emergency stop "
            + (configuration.isHalted ? "SET: nothing starts" : "not set"))
        lines += loaded.notes.map { "  this launch: \($0)" }
        return lines
    }
}

/// Stands where the on-device language model would while model inference is prohibited: never
/// available, and a call fails without reaching the model.
struct ProhibitedSummarizer: ConversationSummarizing {
    struct Prohibited: LocalizedError {
        var errorDescription: String? { "Model inference is prohibited by the device test mode." }
    }

    func isAvailable() async -> Bool { false }
    func prewarm() async {}
    func recap(transcript: String, notes: [String]) async throws -> RecapDraft { throw Prohibited() }
    func update(previous: RecapDraft, newTranscript: String) async throws -> RecapDraft { throw Prohibited() }
    func restate(_ statement: String) async throws -> String { throw Prohibited() }
}
#endif
