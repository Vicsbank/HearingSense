#if DEBUG
import CoreML
import Foundation
import HearingSenseDomain
import SoundEventDetection

/// Debug-only research switch (docs/research/BACKGROUND_INFERENCE_INVESTIGATION.md): launch the
/// app with `--hs-classifier yamnet | mn10 | dymn04` to run a converted third-party model through
/// `CoreMLSoundClassifierBackend` (Core ML, CPU only) instead of Apple's built-in classifier, or
/// with `hybrid-yamnet | hybrid-mn10 | hybrid-dymn04` to run Apple's classifier in the foreground
/// and the third-party model in the background (`SwitchingClassifierBackend`).
/// Without the argument nothing changes.
///
/// The models are not in the repository. Generate and copy them with
/// `tools/experiments/audio_models/install_app_models.sh`; a missing model falls back to Apple's
/// classifier and says so in the event log.
enum ExperimentalClassifier: String, CaseIterable {
    case yamnet, mn10, dymn04

    static let argument = "--hs-classifier"

    static let hybridPrefix = "hybrid-"

    /// The requested model and whether it should only take over in the background.
    static var requested: (model: ExperimentalClassifier, isHybrid: Bool)? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: argument), index + 1 < arguments.count else { return nil }
        let value = arguments[index + 1]
        let isHybrid = value.hasPrefix(hybridPrefix)
        guard let model = ExperimentalClassifier(rawValue: isHybrid ? String(value.dropFirst(hybridPrefix.count)) : value)
        else { return nil }
        return (model, isHybrid)
    }

    var resourceName: String {
        switch self {
        case .yamnet: "YAMNet"
        case .mn10: "EfficientAT_MN10_10s"
        case .dymn04: "EfficientAT_DyMN04_2s"
        }
    }

    var modelID: SoundModelID {
        switch self {
        case .yamnet: .yamnet
        case .mn10: .efficientATMN10
        case .dymn04: .efficientATDyMN04
        }
    }

    func factory() throws -> ClassifierBackendFactory {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "mlmodelc") else {
            throw BackendError.modelUnavailable("\(resourceName).mlmodelc is not in the app bundle")
        }
        // mn10: 2 s of audio repeated into the 10 s input (the configuration the benchmark supports).
        return try CoreMLSoundClassifierBackend.factory(compiledModelAt: url, modelID: modelID, computeUnits: .cpuOnly,
                                                        analysisWindow: self == .mn10 ? 2 : nil)
    }
}
#endif
