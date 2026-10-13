import ConversationUnderstanding
import Foundation
import QwenRuntime

// hs-qwen-probe: runs the real Qwen engine on the Mac (native Swift MLX; no Python).
//   hs-qwen-probe [--hs-qwen-model-dir <dir>] [--file <jsonl of {id, lines}>] [--limit N]
// Prints identity, load time, and for each conversation the raw draft and metrics.
// Synthetic transcripts only. Output contains transcripts' summaries: do not publish real speech.
let arguments = CommandLine.arguments
guard let directory = QwenModelLocator.locate() else {
    print("no complete Qwen checkpoint found"); exit(2)
}
let engine = QwenSummarizationEngine(modelDirectory: directory)
print("engine:", engine.identity.detail)
let t0 = Date()
await engine.prewarm()
print("prewarm (load) seconds:", String(format: "%.2f", Date().timeIntervalSince(t0)), "available:", await engine.isAvailable())

let sample = [
    "so for the chemistry project are we still meeting on Thursday",
    "no Thursday doesn't work the library closes at five that day",
    "what about Saturday morning then around ten",
    "Saturday at ten works but not at the library it's closed on weekends",
    "we could use the study room in the science building room two oh four",
    "actually let's make it Sunday instead of Saturday",
    "the report is due next Wednesday and it needs at least six pages",
]
do {
    let draft = try await engine.recap(transcript: sample.joined(separator: "\n"), notes: [])
    let m = await engine.lastMetrics
    print("title:", draft.title)
    print("summary:", draft.summary)
    for p in draft.keyPoints { print(" -", p) }
    print(String(format: "total %.2fs prompt %d tok (%.2fs) gen %d tok (%.2fs, %.1f tok/s) active %.2f GB peak %.2f GB",
                 m.totalSeconds, m.promptTokens, m.promptSeconds, m.generatedTokens, m.generateSeconds, m.tokensPerSecond,
                 Double(m.activeBytes) / 1e9, Double(m.peakBytes) / 1e9))
} catch {
    print("recap failed:", String(describing: error))
}
