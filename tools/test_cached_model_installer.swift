import CryptoKit
import Foundation

/// Standalone native checks of the actual installer source, no MLX/model execution required.
@main struct InstallerChecks {
    static let revision = "32f3e8ecf65426fc3306969496342d504bfa13f3"
    static let model = "mlx-community/Qwen3.5-4B-MLX-4bit"
    static let fm = FileManager.default

    static func fixture() throws -> URL {
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let staging = root.appendingPathComponent(".incoming-" + revision)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let names = ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors.index.json", "model.safetensors"]
        var files: [CachedModelInstaller.Entry] = []
        for name in names {
            let content = name == "model.safetensors.index.json" ? #"{"weight_map":{"synthetic":"model.safetensors"}}"# : "synthetic"
            let data = Data(content.utf8)
            try data.write(to: staging.appendingPathComponent(name))
            files.append(.init(name: name, bytes: Int64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
        }
        let manifest = CachedModelInstaller.Manifest(version: 1, modelID: model, revision: revision, license: "Apache-2.0", files: files)
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("hearing-sense-model-manifest.json"))
        return root
    }

    static func main() throws {
        var roots: [URL] = []
        defer { for root in roots { try? fm.removeItem(at: root) } }
        let valid = try fixture(); roots.append(valid)
        let first = try CachedModelInstaller.activate(in: valid, modelID: model, revision: revision)
        guard first.files == 5, !first.alreadyInstalled,
              !fm.fileExists(atPath: valid.appendingPathComponent(".incoming-" + revision).path) else { fatalError("Atomic activation failed") }
        let again = try CachedModelInstaller.activate(in: valid, modelID: model, revision: revision)
        guard again.alreadyInstalled else { fatalError("Existing snapshot not recognized") }
        print("PASS atomic activation and verified reuse")

        let damaged = try fixture(); roots.append(damaged)
        try Data("corrupted".utf8).write(to: damaged.appendingPathComponent(".incoming-" + revision + "/model.safetensors"))
        do { _ = try CachedModelInstaller.activate(in: damaged, modelID: model, revision: revision); fatalError("Corruption accepted") }
        catch CachedModelInstaller.Failure.corruptFile { }
        guard !fm.fileExists(atPath: damaged.appendingPathComponent(revision).path) else { fatalError("Corrupted data activated") }
        print("PASS corrupt transfer cannot activate")

        let linked = try fixture(); roots.append(linked)
        let file = linked.appendingPathComponent(".incoming-" + revision + "/tokenizer.json")
        try fm.removeItem(at: file)
        try fm.createSymbolicLink(at: file, withDestinationURL: linked.appendingPathComponent("outside.json"))
        do { _ = try CachedModelInstaller.activate(in: linked, modelID: model, revision: revision); fatalError("Symlink accepted") }
        catch CachedModelInstaller.Failure.corruptFile { }
        print("PASS symlink payload refused")

        let conflict = try fixture(); roots.append(conflict)
        let target = conflict.appendingPathComponent(revision)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let sentinel = target.appendingPathComponent("preserve.txt")
        try Data("preserve existing model".utf8).write(to: sentinel)
        do { _ = try CachedModelInstaller.activate(in: conflict, modelID: model, revision: revision); fatalError("Existing target overwritten") }
        catch CachedModelInstaller.Failure.destinationConflict { }
        guard fm.fileExists(atPath: sentinel.path) else { fatalError("Existing contents lost") }
        print("PASS existing unknown model preserved")

        let extra = try fixture(); roots.append(extra)
        try Data("unverified".utf8).write(to: extra.appendingPathComponent(".incoming-" + revision + "/extra.safetensors"))
        do { _ = try CachedModelInstaller.activate(in: extra, modelID: model, revision: revision); fatalError("Unlisted weights accepted") }
        catch CachedModelInstaller.Failure.invalidManifest { }
        print("PASS unlisted weights refused")
        print("RESULT: 6 checks passed; synthetic metadata/files only; no inference")
    }
}
