import Foundation
import HearingSenseDomain
import Testing
@testable import SpeechPipeline

/// Scripted recognizer results (synthetic): no speech recognition runs in these tests.
@Suite struct TranscriptAssemblerTests {
    static func update(_ text: String, _ start: TimeInterval, _ end: TimeInterval, final: Bool = false,
                       confidence: Double? = nil) -> TranscriptionUpdate
    {
        TranscriptionUpdate(text: text, audioTime: AudioTimeRange(start: start, end: end), isFinal: final,
                            meanConfidence: confidence, minimumConfidence: confidence.map { $0 - 0.1 },
                            producedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func partialResultsReplaceEachOtherUntilTheFinalArrives() {
        var assembler = TranscriptAssembler()
        let changed1 = assembler.apply(Self.update("Your", 0, 1))
        #expect(changed1)
        let changed2 = assembler.apply(Self.update("Your package", 0, 2))
        #expect(changed2)
        let changed3 = assembler.apply(Self.update("Your package", 0, 2.5))  // no visible change
        #expect(!changed3)
        #expect(assembler.text == "Your package" && !assembler.hasFinalText)
        let changed4 = assembler.apply(Self.update("Your package has not arrived.", 0.3, 2.8, final: true, confidence: 0.9))
        #expect(changed4)
        #expect(assembler.text == "Your package has not arrived.")
        #expect(assembler.finalText == assembler.text && assembler.volatileText.isEmpty)
        #expect(assembler.audioTime == AudioTimeRange(start: 0.3, end: 2.8))
    }

    @Test func consecutiveSentencesAreAppendedInOrder() {
        var assembler = TranscriptAssembler()
        assembler.apply(Self.update("Class starts at 3 PM.", 0, 2, final: true))
        assembler.apply(Self.update("Don't", 2, 3))
        #expect(assembler.text == "Class starts at 3 PM. Don't")
        assembler.apply(Self.update("Don't be late.", 2.2, 3.5, final: true))
        #expect(assembler.segments.map(\.text) == ["Class starts at 3 PM.", "Don't be late."])
        #expect(assembler.audioTime == AudioTimeRange(start: 0, end: 3.5))
    }

    @Test func repeatedFinalsAreDroppedAsDuplicates() {
        var assembler = TranscriptAssembler()
        assembler.apply(Self.update("Your package arrived.", 1, 3, final: true))
        assembler.apply(Self.update("Your package arrived.", 1, 3, final: true))  // same audio again
        assembler.apply(Self.update("your package arrived", 3.2, 4, final: true))  // same words right after
        assembler.apply(Self.update("Your package arrived!", 1.1, 2.9, final: true))  // overlapping audio
        #expect(assembler.segments.count == 1 && assembler.duplicatesDropped == 3)
        // The same sentence much later is new speech, not a duplicate.
        assembler.apply(Self.update("Your package arrived.", 20, 22, final: true))
        #expect(assembler.segments.count == 2)
    }

    @Test func punctuationOnlyResultsAndLeadingPunctuationAreCleaned() {
        var assembler = TranscriptAssembler()
        let changed5 = assembler.apply(Self.update(",......................", 0, 5, final: true))
        #expect(!changed5)
        #expect(assembler.isEmpty)
        assembler.apply(Self.update("...  He has   grave doubts.", 5, 8, final: true))
        #expect(assembler.text == "He has grave doubts.")
        let changed6 = assembler.apply(Self.update(" ", 8, 9))
        #expect(!changed6)
    }

    @Test func aPartialCanBePromotedWhenTheRecognizerNeverFinalizes() {
        var assembler = TranscriptAssembler()
        assembler.promoteVolatile()
        #expect(assembler.isEmpty)
        assembler.apply(Self.update("Can you help me", 0, 2))
        assembler.promoteVolatile()
        #expect(assembler.finalText == "Can you help me" && assembler.volatileText.isEmpty)
        #expect(assembler.quality.rating == .unknown)
    }

    @Test func qualityIsWeightedByWordsAndSeparatesGoodFromPoor() {
        var assembler = TranscriptAssembler()
        assembler.apply(Self.update("one two three four five six", 0, 3, final: true, confidence: 0.9))
        assembler.apply(Self.update("seven eight", 3, 4, final: true, confidence: 0.5))
        let quality = assembler.quality
        #expect(abs((quality.meanConfidence ?? 0) - 0.8) < 1e-9)
        #expect(quality.minimumConfidence == 0.4 && quality.wordCount == 8 && quality.rating == .good)
        #expect(TranscriptQuality.assess(meanConfidence: 0.6, minimumConfidence: 0.2, wordCount: 3).rating == .fair)
        #expect(TranscriptQuality.assess(meanConfidence: 0.3, minimumConfidence: 0.1, wordCount: 3).rating == .poor)
        #expect(TranscriptQuality.assess(meanConfidence: nil, minimumConfidence: nil, wordCount: 3).rating == .unknown)
    }

    @Test func textHelpersNormalizeForComparison() {
        #expect(TranscriptText.words(in: "Don’t open — the DOOR, at 7:30!") == ["don't", "open", "the", "door", "at", "7:30"])
        #expect(TranscriptText.normalized("Hello,  World.") == TranscriptText.normalized("hello world"))
        #expect(!TranscriptText.isMeaningful("... ,,") && TranscriptText.isMeaningful("ok."))
    }
}
