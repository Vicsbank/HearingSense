import Foundation
@testable import SemanticAttention
import SemanticEvaluation
import Testing

/// Window 6.2: the instructions may teach by example, but never with a sentence of an
/// evaluation set, and the sealed set must stay apart from everything used for tuning.
@Suite struct SemanticPromptTests {
    private static func words(_ text: String) -> [String] { SemanticText.words(in: text) }

    /// Quoted examples of five words or more in a text (shorter ones are turns of phrase such
    /// as "I need you to", which any sentence may contain).
    private static func examples(in text: String) -> [[String]] {
        text.split(separator: "\"", omittingEmptySubsequences: false).enumerated()
            .filter { $0.offset % 2 == 1 }.map { words(String($0.element)) }.filter { $0.count >= 5 }
    }

    private static func contains(_ sentence: [String], _ phrase: [String]) -> Bool {
        guard sentence.count >= phrase.count else { return false }
        return (0 ... sentence.count - phrase.count).contains { Array(sentence[$0 ..< $0 + phrase.count]) == phrase }
    }

    @Test func noExampleInTheInstructionsIsTakenFromAnEvaluationSet() throws {
        let instructions = [FoundationModelRelevanceReasoner.stagedInstructions, FoundationModelRelevanceReasoner.secondLookInstructions,
                            FoundationModelRelevanceReasoner.repetitionInstructions,
                            FoundationModelRelevanceReasoner.concernInstructions, FoundationModelRelevanceReasoner.groupsInstructions]
        let examples = instructions.flatMap(Self.examples)
        #expect(examples.count >= 5)
        for split in [SemanticDataset.Split.heldout, .sealed, .dev3, .sealed2, .dev4, .sealed3] {
            for item in try SemanticDataset.load(split).items {
                let sentence = Self.words(item.text)
                for example in examples {
                    #expect(!Self.contains(sentence, example) && !(sentence.count >= 5 && Self.contains(example, sentence)),
                            "an example of the instructions occurs in \(split.rawValue)")
                }
            }
        }
    }

    @Test func theSecondSealedSetSharesNothingWithTheSetsUsedForTuning() throws {
        // One everyday sentence of the second sealed set also occurs in the first development
        // set; it is left out of the sealed evaluation and reported.
        let (sealed, excluded) = try SemanticDataset.load(.sealed2).independent()
        #expect(excluded.count <= 2)
        let tuning = try [SemanticDataset.Split.dev, .dev2, .dev3, .heldout, .sealed].flatMap { try SemanticDataset.load($0).items }
        #expect(Set(sealed.items.map(\.profile)).isDisjoint(with: tuning.map(\.profile)))
        #expect(Set(sealed.items.map { $0.text.lowercased() }).isDisjoint(with: tuning.map { $0.text.lowercased() }))
        let goals = Set(sealed.items.map(\.profile)).flatMap { SemanticDataset.goals(for: $0).map { $0.goal.text.lowercased() } }
        let tuned = Set(tuning.map(\.profile)).flatMap { SemanticDataset.goals(for: $0).map { $0.goal.text.lowercased() } }
        #expect(Set(goals).isDisjoint(with: tuned))
        #expect(sealed.items.count >= 240)
    }

    @Test func theThirdSealedSetSharesNothingWithTheSetsUsedForTuning() throws {
        let (sealed, excluded) = try SemanticDataset.load(.sealed3).independent()
        #expect(excluded.count <= 2)
        let tuning = try [SemanticDataset.Split.dev, .dev2, .dev3, .dev4, .heldout, .sealed, .sealed2]
            .flatMap { try SemanticDataset.load($0).items }
        #expect(Set(sealed.items.map(\.profile)).isDisjoint(with: tuning.map(\.profile)))
        #expect(Set(sealed.items.map { $0.text.lowercased() }).isDisjoint(with: tuning.map { $0.text.lowercased() }))
        let goals = Set(sealed.items.map(\.profile)).flatMap { SemanticDataset.goals(for: $0).map { $0.goal.text.lowercased() } }
        let tuned = Set(tuning.map(\.profile)).flatMap { SemanticDataset.goals(for: $0).map { $0.goal.text.lowercased() } }
        #expect(Set(goals).isDisjoint(with: tuned))
        #expect(sealed.items.count >= 300)
        // Three of its five listeners say who they are in an "about me" line, one inside the goals, one nowhere.
        #expect(Set(sealed.items.map(\.profile)).count { !SemanticDataset.about(for: $0).isEmpty } == 3)
        // No rule of the audience analysis was written from one of its sentences: none of the
        // examples in the analyzer's own tests occurs in it (checked here by its words).
        let sentences = Set(sealed.items.map { $0.text.lowercased() })
        for example in ["yellow boat, you launch first.", "peter, your taxi is outside.", "crew a, life jackets on."] {
            #expect(!sentences.contains(example))
        }
    }

    @Test func theAnswerFormIsNotSentWithARequestOfTheCurrentStyle() {
        // The instructions describe the answer (Window 6.2: with the form in the request the model
        // read 160 tokens more, wrote 7 more and was right less often).
        let text = FoundationModelRelevanceReasoner.stagedInstructions
        for field in ["kind, the first that fits", "goal is the number", "verdict:"] { #expect(text.contains(field)) }
        for kind in GeneratedLeanKind.allCases { #expect(text.contains(kind.rawValue + ":"), "kind \(kind.rawValue) is not described") }
        #expect(FoundationModelRelevanceReasoner.current.style == .staged)
    }

    @Test func arrivalPatternsAreRepeatableAndOrdered() {
        for pattern in ["3.0", "1.0", "bursty", "dense"] {
            let offsets = SemanticStreamBenchmark.offsets(pattern: pattern, count: 40)
            #expect(offsets.count == 40)
            #expect(offsets == offsets.sorted())
            #expect(offsets == SemanticStreamBenchmark.offsets(pattern: pattern, count: 40))
        }
        #expect(SemanticStreamBenchmark.offsets(pattern: "dense", count: 40)[0] == 20)
    }
}
