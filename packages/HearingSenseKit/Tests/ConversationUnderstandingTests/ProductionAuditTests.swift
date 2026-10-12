import Foundation
import Testing

/// Window 7: checks on the app's own sources (not on behaviour): the product must not contain
/// the continuous semantic relevance classification of Windows 6–6.3. The research code stays
/// in the `SemanticAttention` package module; the app does not link it.
///
/// Reads the repository next to this file, so it runs on the Mac (`swift test`) only.
@Suite struct ProductionAuditTests {
    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let appSources = repository.appendingPathComponent("apps/ios")

    static func swiftFiles() throws -> [(path: String, text: String)] {
        let enumerator = try #require(FileManager.default.enumerator(at: appSources, includingPropertiesForKeys: nil))
        var files: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append((url.path.replacingOccurrences(of: repository.path + "/", with: ""), try String(contentsOf: url, encoding: .utf8)))
        }
        return files
    }

    #if os(macOS)
    @Test func theAppDoesNotUseTheSemanticAttentionModule() throws {
        let files = try Self.swiftFiles()
        #expect(files.count > 20)
        let banned = ["import SemanticAttention", "SemanticAttentionEngine", "FoundationModelRelevanceReasoner",
                      "SemanticRelevanceReasoning", "AttentionGoal", "SentenceEmbeddingScorer", "ListenerProfile"]
        for file in files {
            for word in banned {
                #expect(!file.text.contains(word), "\(file.path) mentions \(word)")
            }
        }
    }

    @Test func theAppTargetsDoNotLinkTheSemanticAttentionModule() throws {
        let project = try String(contentsOf: Self.appSources.appendingPathComponent("HearingSense.xcodeproj/project.pbxproj"),
                                 encoding: .utf8)
        #expect(!project.contains("SemanticAttention"))
        #expect(project.contains("ConversationUnderstanding"))
    }

    /// The language model is reached through two package types only: the recap summarizer
    /// (a summary the user asked for) and the Window 3 interpreter, whose automatic headline is
    /// off in release builds. The app itself opens no model session.
    @Test func theAppOpensNoLanguageModelSessionOfItsOwn() throws {
        for file in try Self.swiftFiles() {
            #expect(!file.text.contains("LanguageModelSession"), "\(file.path) opens a language model session")
            #expect(!file.text.contains("import FoundationModels"), "\(file.path) imports FoundationModels")
        }
    }
    #endif
}
