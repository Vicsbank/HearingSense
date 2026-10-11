#if DEBUG
import HearingSenseDomain
import IslandPresentation
import IslandViews
import SoundEventDetection
import SwiftUI

/// Every classifier label with the icon it resolves to (Window 6), for a visual review of the
/// icon mapping. Each row draws the icon with the widget extension's own views at the sizes of
/// the Dynamic Island: compact, minimal and the icon alone on a light background.
struct SoundIconGalleryView: View {
    private struct Entry: Identifiable {
        let label: SoundLabel
        let displayName: String
        let kind: SoundEventKind
        let symbol: SoundSymbol
        var id: String { label.rawValue }
    }

    private enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case custom = "Drawn by the app"
        case specific = "Label icon"
        case fallback = "Kind or category icon"
        var id: String { rawValue }
    }

    @State private var search = ""
    @State private var filter = Filter.all

    private static let entries: [Entry] = {
        let taxonomy = SoundTaxonomy.appleV1
        return taxonomy.mappedLabels.sorted().map { label in
            let kind = taxonomy.definition(for: label).kind
            return Entry(label: label, displayName: taxonomy.displayName(for: label), kind: kind,
                         symbol: SoundSymbolCatalog.symbol(label: label, kindID: kind.id, category: kind.category))
        }
    }()

    private var shown: [Entry] {
        Self.entries.filter { entry in
            let matchesFilter = switch filter {
            case .all: true
            case .custom: entry.symbol.customGlyph != nil
            case .specific: entry.symbol.level == .label
            case .fallback: entry.symbol.level != .label
            }
            let text = search.trimmingCharacters(in: .whitespaces).lowercased()
            return matchesFilter && (text.isEmpty || entry.label.rawValue.contains(text)
                || entry.displayName.lowercased().contains(text) || entry.symbol.name.contains(text))
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                LabeledContent("Labels shown", value: "\(shown.count) of \(Self.entries.count)")
            } footer: {
                Text("Compact island, minimal island, then the icon on a light background. The island itself appears only while the app is not on screen.")
            }
            Section {
                ForEach(shown) { entry in
                    row(entry)
                }
            }
        }
        .searchable(text: $search, prompt: "Label, name or symbol")
        .navigationTitle("Sound icons")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ entry: Entry) -> some View {
        let content = IslandContent(mode: .ambient, symbolName: entry.symbol.name, spokenLabel: entry.displayName, since: .now)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                IslandCompactPreview(content: content)
                IslandMinimal(content)
                    .frame(width: 37, height: 37)
                    .background(.black, in: Circle())
                    .environment(\.colorScheme, .dark)
                SoundSymbolImage(entry.symbol.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.black)
                    .frame(width: 37, height: 37)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName).font(.subheadline.weight(.medium))
                Text("\(entry.label.rawValue) · \(entry.kind.displayName) · \(entry.symbol.name) (\(entry.symbol.level.rawValue))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.displayName): \(entry.symbol.customGlyph?.visualDescription ?? "symbol \(entry.symbol.name)")")
    }
}
#endif
