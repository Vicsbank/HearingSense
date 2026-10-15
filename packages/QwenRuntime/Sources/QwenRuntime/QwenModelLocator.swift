import ConversationUnderstanding
import Foundation

/// Where the Qwen checkpoint lives and what it is (Window 9). Nothing here downloads anything.
public enum QwenModelLocator {
    public static let modelID = "mlx-community/Qwen3.5-4B-MLX-4bit"
    /// The snapshot that was benchmarked and validated (Hugging Face commit).
    public static let validatedRevision = "32f3e8ecf65426fc3306969496342d504bfa13f3"
    public static let runtimeDescription: String = {
        let version = "mlx-swift-lm 3.32.3 / mlx-swift 0.32.3 / swift-transformers 1.3.5"
        #if targetEnvironment(simulator)
        return version + " + hearing-sense simulator-cpu-v1 adapter"
        #else
        return version + " / native Metal backend"
        #endif
    }()

    /// Files that must exist for the model to load.
    static let requiredFiles = ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors.index.json"]

    /// Candidate directories, in order:
    /// 1. the `HS_QWEN_MODEL_DIR` environment variable or the `--hs-qwen-model-dir <path>` launch argument
    ///    (development: the Simulator and the Mac read the host's files directly);
    /// 2. `Application Support/Models/Qwen3.5-4B-MLX-4bit` inside the app (where an installed copy lives on a device);
    /// 3. the Hugging Face cache snapshot of the benchmark checkpoint on the Mac (Simulator and Mac only).
    public static func candidates(arguments: [String] = ProcessInfo.processInfo.arguments,
                                  environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL]
    {
        var urls: [URL] = []
        if let index = arguments.firstIndex(of: "--hs-qwen-model-dir"), arguments.indices.contains(index + 1) {
            urls.append(URL(fileURLWithPath: arguments[index + 1]))
        }
        if let path = environment["HS_QWEN_MODEL_DIR"] { urls.append(URL(fileURLWithPath: path)) }
        if let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                                                      create: false)
        {
            let root = support.appendingPathComponent("Models/Qwen3.5-4B-MLX-4bit", isDirectory: true)
            urls.append(root.appendingPathComponent(validatedRevision, isDirectory: true))
            urls.append(root) // compatibility with an earlier flat installation
        }
        #if targetEnvironment(simulator) || os(macOS)
        let home = environment["SIMULATOR_HOST_HOME"] ?? NSHomeDirectory()
        urls.append(URL(fileURLWithPath: home).appendingPathComponent(
            ".cache/huggingface/hub/models--mlx-community--Qwen3.5-4B-MLX-4bit/snapshots/\(validatedRevision)", isDirectory: true))
        #endif
        return urls
    }

    /// The first candidate that holds a complete checkpoint.
    public static func locate(arguments: [String] = ProcessInfo.processInfo.arguments,
                              environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        candidates(arguments: arguments, environment: environment).first { problem(with: $0) == nil }
    }

    /// Why `directory` cannot be loaded (a code); nil when it holds a complete checkpoint.
    public static func problem(with directory: URL) -> String? {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "qwen_model_not_installed"
        }
        for file in requiredFiles where !manager.fileExists(atPath: directory.appendingPathComponent(file).path) {
            return "qwen_model_incomplete"
        }
        guard let weights = try? manager.contentsOfDirectory(atPath: directory.path), weights.contains(where: { $0.hasSuffix(".safetensors") })
        else { return "qwen_weights_missing" }
        return nil
    }

    /// The identity of the checkpoint in `directory`, read from its files. The revision is the
    /// snapshot folder's name when the directory is a Hugging Face snapshot, otherwise "unknown".
    public static func identity(of directory: URL) -> SummarizationEngineIdentity {
        var quantization = "unknown"
        if let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let quant = json["quantization"] as? [String: Any]
        {
            let bits = quant["bits"] as? Int ?? 0, group = quant["group_size"] as? Int ?? 0, mode = quant["mode"] as? String ?? "?"
            quantization = "\(bits)-bit \(mode), group \(group)"
        }
        let last = directory.lastPathComponent
        let isSnapshot = last.count == 40 && last.allSatisfy(\.isHexDigit)
        return SummarizationEngineIdentity(kind: .qwen, modelID: modelID, revision: isSnapshot ? last : "unknown",
                                           quantization: quantization, runtime: runtimeDescription)
    }
}
