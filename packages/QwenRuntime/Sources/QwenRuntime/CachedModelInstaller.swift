import CryptoKit
import Foundation

/// Offline development delivery: checks the cable-transferred cache copy before an atomic
/// directory move. Checksums detect transfer corruption; this is not a signed OTA downloader.
public enum CachedModelInstaller {
    public struct Entry: Codable, Sendable {
        public var name: String
        public var bytes: Int64
        public var sha256: String
    }
    public struct Manifest: Codable, Sendable {
        public var version: Int
        public var modelID: String
        public var revision: String
        public var license: String
        public var files: [Entry]
    }
    public struct Receipt: Sendable {
        public var files: Int
        public var bytes: Int64
        public var alreadyInstalled: Bool
    }
    public enum Failure: String, Error { case invalidManifest, unsafeFile, corruptFile, missingRequiredFile, destinationConflict }

    /// Only touches the two reserved model directories below `root`, never History/settings.
    /// Run on a background executor: validation streams the multi-GB weight file.
    public static func activate(in root: URL, modelID: String, revision: String) throws -> Receipt {
        guard revision.count == 40, revision.allSatisfy(\.isHexDigit) else { throw Failure.invalidManifest }
        let incoming = root.appendingPathComponent(".incoming-" + revision, isDirectory: true)
        let target = root.appendingPathComponent(revision, isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            do {
                let manifest = try verify(target, modelID: modelID, revision: revision)
                return Receipt(files: manifest.files.count, bytes: manifest.files.reduce(0) { $0 + $1.bytes }, alreadyInstalled: true)
            } catch { throw Failure.destinationConflict }
        }
        let manifest = try verify(incoming, modelID: modelID, revision: revision)
        try Task.checkCancellation()
        try fm.moveItem(at: incoming, to: target)
        var folder = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        return Receipt(files: manifest.files.count, bytes: manifest.files.reduce(0) { $0 + $1.bytes }, alreadyInstalled: false)
    }

    private static func verify(_ directory: URL, modelID: String, revision: String) throws -> Manifest {
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw Failure.unsafeFile }
        let manifestURL = directory.appendingPathComponent("hearing-sense-model-manifest.json")
        let manifestAttributes = try manifestURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard manifestAttributes.isSymbolicLink != true, manifestAttributes.isRegularFile == true else { throw Failure.unsafeFile }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.version == 1, manifest.modelID == modelID, manifest.revision == revision,
              manifest.license == "Apache-2.0", !manifest.files.isEmpty,
              Set(manifest.files.map(\.name)).count == manifest.files.count else { throw Failure.invalidManifest }
        // The loader scans this directory for weights. Unlisted leftovers must not become
        // part of a checkpoint that is reported as checksum-verified.
        let actualNames = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        guard actualNames == Set(manifest.files.map(\.name) + ["hearing-sense-model-manifest.json"])
        else { throw Failure.invalidManifest }
        let required = ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors.index.json"]
        guard required.allSatisfy({ name in manifest.files.contains { $0.name == name } }),
              manifest.files.contains(where: { $0.name.hasSuffix(".safetensors") }) else { throw Failure.missingRequiredFile }
        for entry in manifest.files {
            guard !entry.name.isEmpty, entry.name != ".", entry.name != "..",
                  !entry.name.contains("/"), !entry.name.contains("\\"), entry.bytes > 0,
                  entry.sha256.count == 64, entry.sha256.allSatisfy(\.isHexDigit) else { throw Failure.unsafeFile }
            let url = directory.appendingPathComponent(entry.name)
            let attributes = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            guard attributes.isSymbolicLink != true, attributes.isRegularFile == true,
                  Int64(attributes.fileSize ?? -1) == entry.bytes else { throw Failure.corruptFile }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var digest = SHA256()
            while let chunk = try file.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                digest.update(data: chunk)
            }
            guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == entry.sha256.lowercased()
            else { throw Failure.corruptFile }
        }
        let index = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("model.safetensors.index.json"))) as? [String: Any]
        guard let weights = index?["weight_map"] as? [String: String], !weights.isEmpty,
              Set(weights.values).allSatisfy({ shard in manifest.files.contains { $0.name == shard } })
        else { throw Failure.missingRequiredFile }
        return manifest
    }
}
