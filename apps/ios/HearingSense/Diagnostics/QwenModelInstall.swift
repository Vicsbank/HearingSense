#if DEBUG
import Foundation
import QwenRuntime

/// Explicit offline model deployment, with the microphone/model inference still prohibited.
enum QwenModelInstall {
    static let argument = "--hs-w9-install-cached-model"
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(argument) }
    static let fileName = "hearing-sense-w9-model-install.txt"

    static func run() async {
        var lines = ["Window 9 cached model installation · \(Date.now.formatted(.iso8601))",
                     "No microphone, transcription or model inference. Cached weights only."]
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let root = support.appendingPathComponent("Models/Qwen3.5-4B-MLX-4bit", isDirectory: true)
        let report = documents.appendingPathComponent(fileName)
        try? Data((lines + ["Checksum validation in progress."]).joined(separator: "\n").utf8).write(to: report, options: .atomic)
        let task = Task.detached(priority: .utility) {
            try CachedModelInstaller.activate(in: root, modelID: QwenModelLocator.modelID, revision: QwenModelLocator.validatedRevision)
        }
        do {
            let receipt = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            lines.append("Revision: \(QwenModelLocator.validatedRevision)")
            lines.append("Verified \(receipt.files) files / \(receipt.bytes) bytes; already installed: \(receipt.alreadyInstalled).")
            lines.append("RESULT: installed, checksums verified; next launch can use the snapshot.")
        } catch {
            let reason = (error as? CachedModelInstaller.Failure)?.rawValue ?? String(describing: type(of: error))
            lines.append("RESULT: not activated; failure \(reason).")
        }
        try? Data(lines.joined(separator: "\n").utf8).write(to: report, options: .atomic)
    }
}
#endif
