import Foundation
import HearingSenseDomain
import Testing
@testable import SoundEventDetection

@Suite struct SoundTaxonomyTests {
    let taxonomy = SoundTaxonomy.appleV1

    @Test func mapsEveryLabelOfTheRecordedMacOSInventory() throws {
        let text = try String(contentsOf: RepositoryPaths.macOSLabelInventory, encoding: .utf8)
        let labels = text.split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }.map { SoundLabel(String($0)) }
        #expect(labels.count == 303)
        let coverage = taxonomy.coverage(of: labels)
        #expect(coverage.notInTaxonomy.isEmpty, "Unmapped: \(coverage.notInTaxonomy)")
        #expect(coverage.notReportedByClassifier.isEmpty, "Unknown to the model: \(coverage.notReportedByClassifier)")
    }

    /// Live check against the classifier of the OS running the tests (macOS or iOS Simulator).
    @Test func matchesTheLiveClassifierInventory() throws {
        let catalog = try SoundClassifierCatalog.load()
        let coverage = taxonomy.coverage(of: catalog.labels)
        #expect(coverage.isExactMatch, "not in taxonomy \(coverage.notInTaxonomy), missing \(coverage.notReportedByClassifier)")
        #expect(catalog.labels.count == Set(catalog.labels).count)
    }

    @Test func kindIdentifiersAreUniqueAndEveryCategoryButOtherIsUsed() {
        let ids = taxonomy.definitions.map(\.kind.id)
        #expect(ids.count == Set(ids).count)
        let used = Set(taxonomy.definitions.map(\.kind.category))
        #expect(used == Set(SoundCategory.allCases))
    }

    @Test func keepsOriginalIdentifiersAndProvidesDisplayNames() {
        #expect(taxonomy.definition(for: "dog_bark").kind.id == "dog")
        #expect(taxonomy.category(for: "car_horn") == .alerts)
        #expect(taxonomy.category(for: "speech") == .speech)
        #expect(taxonomy.category(for: "rain") == .weatherNature)
        #expect(taxonomy.category(for: "knock") == .household)
        #expect(taxonomy.category(for: "glass_breaking") == .impacts)
        #expect(taxonomy.category(for: "wind_noise_microphone") == .other)
        #expect(taxonomy.displayName(for: "dog_bark") == "Dog bark")  // generated
        #expect(taxonomy.displayName(for: "gunshot_gunfire") == "Gunshot")  // curated
        #expect(SoundLabel("dog_bark").rawValue == "dog_bark")
    }

    @Test func unknownLabelsFallBackToOtherInsteadOfDisappearing() {
        let definition = taxonomy.definition(for: "label_from_a_future_os")
        #expect(definition.kind.id == "unmapped")
        #expect(definition.kind.category == .other)
        #expect(!taxonomy.isMapped("label_from_a_future_os"))
    }

    @Test func silenceNeverProducesEvents() {
        #expect(!taxonomy.definition(for: "silence").producesEvents)
        #expect(taxonomy.definitions.filter { !$0.producesEvents }.map(\.kind.id) == ["silence"])
    }

    @Test func everyKindHasARule() {
        let policy = DetectionPolicy.standard
        for definition in taxonomy.definitions {
            let rule = policy.rule(for: definition)
            #expect(rule.sustainScore <= rule.enterScore)
            #expect(rule.enterScore >= policy.displayFloor)
        }
    }
}
