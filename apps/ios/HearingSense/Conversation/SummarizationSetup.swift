import ConversationUnderstanding
import Foundation
import QwenRuntime

/// Builds the app's summarization engines (Window 9): Qwen3.5-4B first, Apple's on-device model
/// as the fallback. Nothing is downloaded here; Qwen is used when its checkpoint is installed
/// (see `QwenModelLocator` and docs/research/QWEN35_HEARING_SENSE_INTEGRATION.md).
enum SummarizationSetup {
    /// Launch arguments for tests (Debug builds): `--hs-engine apple` skips Qwen;
    /// `--hs-engine qwen-missing` points Qwen at a directory that does not exist, to exercise the fallback.
    static var forcedEngine: String? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--hs-engine"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
        #else
        nil
        #endif
    }

    static func makeCoordinator() -> SummarizationCoordinator {
        var primary: (any SummarizationEngine)?
        switch forcedEngine {
        case "apple":
            primary = nil
        case "qwen-missing":
            primary = QwenSummarizationEngine(modelDirectory: URL(fileURLWithPath: "/nonexistent/hearing-sense-qwen"))
        default:
            // Not installed: the engine is still created, so that the fallback reason is recorded
            // ("qwen_model_not_installed") instead of silently using Apple's model.
            let directory = QwenModelLocator.locate() ?? QwenModelLocator.candidates().first
                ?? URL(fileURLWithPath: "/nonexistent/hearing-sense-qwen")
            primary = QwenSummarizationEngine(modelDirectory: directory)
        }
        return SummarizationCoordinator(primary: primary, fallback: AppleFoundationSummarizationEngine())
    }
}
