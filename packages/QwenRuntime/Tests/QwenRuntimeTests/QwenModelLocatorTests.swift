import Foundation
import Testing
@testable import QwenRuntime

@Test func missingDirectoryIsReported() {
    #expect(QwenModelLocator.problem(with: URL(fileURLWithPath: "/nonexistent/qwen")) == "qwen_model_not_installed")
}

@Test func launchArgumentComesFirst() {
    let urls = QwenModelLocator.candidates(arguments: ["app", "--hs-qwen-model-dir", "/x/y"], environment: [:])
    #expect(urls.first?.path == "/x/y")
}
