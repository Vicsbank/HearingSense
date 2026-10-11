// macOS only (NSImage, PNG export); the tool is built for iOS as well when the package's tests run there.
#if canImport(AppKit)
import AppKit
import Foundation
import HearingSenseDomain
import IslandPresentation
import IslandViews
import SoundEventDetection
import SwiftUI

/// Pictures of the sound icons for a visual review (Window 6): the views of the Live Activity
/// (`IslandCompactTrailing`, `IslandMinimal`, `SoundSymbolImage`) rendered on the Mac at their
/// point sizes. A rendering of the real views, not a photograph of a Dynamic Island: fonts and
/// symbol shapes are the Mac's.
@MainActor
enum IconSheets {
    static func write(to directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var files: [URL] = []
        func save(_ view: some View, _ name: String, scale: CGFloat) throws {
            let renderer = ImageRenderer(content: view)
            renderer.scale = scale
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else { throw CocoaError(.fileWriteUnknown) }
            let url = directory.appendingPathComponent(name)
            try png.write(to: url)
            files.append(url)
        }
        try save(RepresentativeSheet(), "representative_island_sizes.png", scale: 4)
        try save(CustomGlyphSheet(), "custom_glyphs.png", scale: 4)
        let labels = SoundTaxonomy.appleV1.mappedLabels.sorted()
        let half = (labels.count + 1) / 2
        try save(AllLabelsSheet(labels: Array(labels[..<half])), "all_labels_1.png", scale: 3)
        try save(AllLabelsSheet(labels: Array(labels[half...])), "all_labels_2.png", scale: 3)
        return files
    }

    static func symbol(_ label: String) -> SoundSymbol {
        let kind = SoundTaxonomy.appleV1.definition(for: SoundLabel(label)).kind
        return SoundSymbolCatalog.symbol(label: SoundLabel(label), kindID: kind.id, category: kind.category)
    }

    static func ambient(_ label: String) -> IslandContent {
        IslandContent(mode: .ambient, symbolName: symbol(label).name, spokenLabel: label, since: Date(timeIntervalSince1970: 0))
    }

    static let representative = ["cough", "sneeze", "snoring", "laughter", "crying_sobbing", "screaming", "whistling",
                                 "speech", "chatter", "shout", "knock", "door_bell", "glass_breaking", "siren",
                                 "smoke_detector", "car_horn", "dog_bark", "music", "rain", "wind", "applause",
                                 "person_walking"]
}

/// A compact island of about the real proportions: the app's glyph left of the camera, the
/// sound's icon right of it.
private struct CompactIsland: View {
    let content: IslandContent

    var body: some View {
        HStack(spacing: 0) {
            IslandCompactLeading(content).frame(width: 30, alignment: .leading)
            Capsule().fill(Color(white: 0.12)).frame(width: 92, height: 26)
            IslandCompactTrailing(content).frame(width: 30, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 37)
        .background(Color.black, in: Capsule())
    }
}

private struct MinimalIsland: View {
    let content: IslandContent

    var body: some View {
        IslandMinimal(content).frame(width: 37, height: 37).background(Color.black, in: Circle())
    }
}

private struct RepresentativeSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Compact (15 pt) · minimal (14 pt) · expanded (26 pt) · light appearance (15 pt, 28 pt)")
                .font(.system(size: 11, weight: .semibold))
            ForEach(IconSheets.representative, id: \.self) { label in
                let content = IconSheets.ambient(label)
                HStack(spacing: 14) {
                    Text(label).font(.system(size: 11, design: .monospaced)).frame(width: 120, alignment: .leading)
                    CompactIsland(content: content)
                    MinimalIsland(content: content)
                    IslandExpandedLeading(content).padding(4).background(Color.black, in: RoundedRectangle(cornerRadius: 12))
                    HStack(spacing: 12) {
                        SoundSymbolImage(content.symbolName).font(.system(size: 15, weight: .medium))
                        SoundSymbolImage(content.symbolName).font(.system(size: 28, weight: .medium))
                    }
                    .foregroundStyle(Color.black)
                    .frame(width: 80, height: 44)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                    Text(content.symbolName).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                        .frame(width: 190, alignment: .leading)
                }
            }
        }
        .padding(16)
        .background(Color(white: 0.85))
        .environment(\.colorScheme, .light)
    }
}

private struct CustomGlyphSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(CustomSoundGlyph.allCases, id: \.self) { glyph in
                HStack(spacing: 16) {
                    ForEach([14, 15, 26, 64] as [CGFloat], id: \.self) { size in
                        SoundSymbolImage(glyph.rawValue).font(.system(size: size, weight: .medium))
                            .foregroundStyle(.mint)
                            .frame(width: max(size * 1.5, 30), height: max(size * 1.4, 30))
                    }
                    Text("\(glyph.rawValue) — \(glyph.visualDescription)").font(.system(size: 11)).foregroundStyle(.white)
                }
            }
        }
        .padding(16)
        .background(Color.black)
    }
}

private struct AllLabelsSheet: View {
    let labels: [SoundLabel]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(150), spacing: 4), count: 6), alignment: .leading, spacing: 4) {
            ForEach(labels, id: \.self) { label in
                let symbol = IconSheets.symbol(label.rawValue)
                HStack(spacing: 6) {
                    SoundSymbolImage(symbol.name).font(.system(size: 15, weight: .medium)).foregroundStyle(.mint)
                        .frame(width: 26, height: 22)
                    Text(label.rawValue).font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(symbol.level == .label ? Color.white : Color(white: 0.6))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .frame(width: 6 * 154 + 24)
        .background(Color.black)
    }
}
#endif
