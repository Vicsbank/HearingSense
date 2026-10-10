import Attention
import Foundation
import HearingSenseDomain
import IslandPresentation
import SoundEventDetection
import Testing
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@Suite struct SoundSymbolCatalogTests {
    let taxonomy = SoundTaxonomy.appleV1

    private func symbolExists(_ name: String) -> Bool {
        #if canImport(UIKit)
        UIImage(systemName: name) != nil
        #elseif canImport(AppKit)
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        #else
        true
        #endif
    }

    @Test func everyClassifierLabelResolvesToASymbol() {
        let labels = taxonomy.mappedLabels
        #expect(labels.count == 303)
        var levels: [SoundSymbolLevel: Int] = [:]
        for label in labels {
            let kind = taxonomy.definition(for: label).kind
            let symbol = SoundSymbolCatalog.symbol(label: label, kindID: kind.id, category: kind.category)
            #expect(!symbol.name.isEmpty)
            levels[symbol.level, default: 0] += 1
        }
        // Only `silence` (which never becomes an event) is left to the category symbol.
        #expect(levels[.category, default: 0] == 1)
        #expect(levels[.label, default: 0] > 100)
    }

    @Test func everyEventKindHasItsOwnSymbol() {
        for definition in taxonomy.definitions + [taxonomy.unmappedKind] where definition.producesEvents {
            #expect(SoundSymbolCatalog.kindSymbols[definition.kind.id] != nil, "no symbol for kind \(definition.kind.id)")
        }
    }

    @Test func theTablesNameOnlyLabelsAndKindsThatExist() {
        let labels = Set(taxonomy.mappedLabels.map(\.rawValue))
        #expect(Set(SoundSymbolCatalog.labelSymbols.keys).subtracting(labels).isEmpty)
        let kinds = Set(taxonomy.definitions.map(\.kind.id) + ["unmapped"])
        #expect(Set(SoundSymbolCatalog.kindSymbols.keys).subtracting(kinds).isEmpty)
    }

    @Test func everySymbolNameExistsOnThisSystem() {
        let names = SoundSymbolCatalog.allSymbolNames.union(IslandSymbol.all)
            .union(AttentionCategory.allCases.map(\.systemImage))
            .union(["exclamationmark", "exclamationmark.2", "circle.fill", "questionmark.circle"])
        let missing = names.filter { !symbolExists($0) }.sorted()
        #expect(missing.isEmpty, "not SF Symbols here: \(missing)")
    }

    @Test func specificLabelsWinOverTheirKind() {
        func name(_ label: String) -> String {
            let kind = taxonomy.definition(for: SoundLabel(label)).kind
            return SoundSymbolCatalog.symbol(label: SoundLabel(label), kindID: kind.id, category: kind.category).name
        }
        #expect(name("rain") == "cloud.rain")
        #expect(name("thunderstorm") == "cloud.bolt.rain")
        #expect(name("dog_bark") == "dog")
        #expect(name("bird_chirp_tweet") == "bird")
        #expect(name("person_walking") == "figure.walk")
        #expect(name("person_shuffling") == "shoeprints.fill")
        #expect(name("knock") == "door.left.hand.closed")
        #expect(name("door_bell") == "bell.and.waves.left.and.right")
        #expect(name("motorcycle") == "motorcycle")
        #expect(name("piano") == "pianokeys")
        #expect(name("music") == "music.note")
        #expect(name("wind") == "wind")
    }

    @Test func anUnknownLabelFallsBackToItsKindThenItsCategory() {
        let known = SoundSymbolCatalog.symbol(label: "hovercraft_hum", kindID: "road_vehicle", category: .transportation)
        #expect(known == SoundSymbol(name: "car.side", level: .kind))
        let unknown = SoundSymbolCatalog.symbol(label: "hovercraft_hum", kindID: "hovercraft", category: .transportation)
        #expect(unknown == SoundSymbol(name: SoundCategory.transportation.systemImage, level: .category))
    }
}
