import IslandPresentation
import SwiftUI

/// The picture for a symbol name: an SF Symbol, or one of the app's own drawings
/// (`CustomSoundGlyph`). Use it wherever a sound's icon is drawn, in place of
/// `Image(systemName:)`. It takes its size from the font and its colour from the foreground
/// style, like a symbol image.
public struct SoundSymbolImage: View {
    let name: String

    public init(_ name: String) {
        self.name = name
    }

    public var body: some View {
        if let glyph = CustomSoundGlyph(symbolName: name) {
            // An invisible symbol of the same font gives the drawing the size a symbol would have.
            Image(systemName: "circle")
                .hidden()
                .overlay {
                    GeometryReader { proxy in
                        // A little larger than the circle symbol, to match the weight of pictorial
                        // symbols (a bell, a dog) beside it; the overflow stays within the line height.
                        let side = min(proxy.size.width, proxy.size.height) * SoundGlyphShape.scale
                        ZStack {
                            SoundGlyphShape(glyph: glyph, part: .fill).fill()
                            SoundGlyphShape(glyph: glyph, part: .stroke)
                                .stroke(style: StrokeStyle(lineWidth: side * SoundGlyphShape.lineWidth, lineCap: .round,
                                                           lineJoin: .round))
                        }
                        .frame(width: side, height: side)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                }
        } else {
            Image(systemName: name)
        }
    }
}

/// The geometry of the custom glyphs, in a unit square (y down). Each glyph has a part that is
/// filled and a part that is stroked with one round line; both use the foreground style, so a
/// glyph never depends on colour. Shapes are kept coarse: at the compact size of the Dynamic
/// Island a glyph is about 17 points wide.
struct SoundGlyphShape: Shape {
    enum Part { case fill, stroke }

    /// Line width as a fraction of the glyph's side.
    static let lineWidth: CGFloat = 0.095
    /// Size relative to the `circle` symbol of the same font.
    static let scale: CGFloat = 1.2

    var glyph: CustomSoundGlyph
    var part: Part

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        var builder = Builder()
        Self.draw(glyph, into: &builder)
        let unit = part == .fill ? builder.fill : builder.stroke
        return unit.applying(CGAffineTransform(translationX: origin.x, y: origin.y).scaledBy(x: side, y: side))
    }

    struct Builder {
        var fill = Path()
        var stroke = Path()

        mutating func line(_ points: (CGFloat, CGFloat)...) {
            guard let first = points.first else { return }
            stroke.move(to: CGPoint(x: first.0, y: first.1))
            for point in points.dropFirst() { stroke.addLine(to: CGPoint(x: point.0, y: point.1)) }
        }

        mutating func ring(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) {
            stroke.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }

        mutating func dot(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) {
            fill.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }

        mutating func oval(_ x: CGFloat, _ y: CGFloat, _ radiusX: CGFloat, _ radiusY: CGFloat) {
            fill.addEllipse(in: CGRect(x: x - radiusX, y: y - radiusY, width: radiusX * 2, height: radiusY * 2))
        }

        /// A stroked arc; angles in degrees, clockwise on screen from the positive x axis.
        mutating func arc(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat, from start: Double, to end: Double) {
            // Start a new subpath at the arc's first point; otherwise the arc is joined to
            // whatever was drawn before it.
            let radians = start * .pi / 180
            stroke.move(to: CGPoint(x: x + radius * CGFloat(cos(radians)), y: y + radius * CGFloat(sin(radians))))
            stroke.addArc(center: CGPoint(x: x, y: y), radius: radius, startAngle: .degrees(start), endAngle: .degrees(end),
                          clockwise: false)
        }

        /// A filled drop with its point upwards.
        mutating func drop(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) {
            var path = Path()
            path.move(to: CGPoint(x: x, y: y - radius * 2.1))
            path.addLine(to: CGPoint(x: x + radius * 0.92, y: y - radius * 0.4))
            path.addArc(center: CGPoint(x: x, y: y), radius: radius, startAngle: .degrees(-24), endAngle: .degrees(204),
                        clockwise: false)
            path.closeSubpath()
            fill.addPath(path)
        }

        /// A head seen from the side, facing right, with the mouth open: a ring with a wedge cut out.
        mutating func openMouthHead(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat, opening: Double) {
            arc(x, y, radius, from: opening, to: 360 - opening)
            let radians = opening * .pi / 180
            let dx = radius * CGFloat(cos(radians)), dy = radius * CGFloat(sin(radians))
            let upper = (x + dx, y - dy)
            let lower = (x + dx, y + dy)
            line(upper, (x + radius * 0.25, y), lower)
        }
    }

    static func draw(_ glyph: CustomSoundGlyph, into b: inout Builder) {
        switch glyph {
        case .cough:
            b.openMouthHead(0.36, 0.52, 0.31, opening: 30)
            b.line((0.24, 0.36), (0.40, 0.40))            // eye squeezed shut
            b.line((0.74, 0.52), (0.95, 0.52))            // cough marks
            b.line((0.72, 0.33), (0.90, 0.22))
            b.line((0.72, 0.71), (0.90, 0.82))
        case .sneeze:
            b.openMouthHead(0.34, 0.50, 0.30, opening: 34)
            b.line((0.22, 0.34), (0.38, 0.38))
            for (x, y, r) in [(0.70, 0.50, 0.050), (0.84, 0.36, 0.045), (0.86, 0.60, 0.045), (0.74, 0.74, 0.040),
                              (0.72, 0.26, 0.040), (0.95, 0.47, 0.035)] as [(CGFloat, CGFloat, CGFloat)]
            {
                b.dot(x, y, r)
            }
        case .snore:
            b.ring(0.38, 0.60, 0.33)
            b.line((0.20, 0.55), (0.32, 0.55))            // closed eyes
            b.line((0.44, 0.55), (0.56, 0.55))
            b.oval(0.38, 0.75, 0.06, 0.07)
            b.line((0.60, 0.20), (0.73, 0.20), (0.60, 0.33), (0.73, 0.33))
            b.line((0.78, 0.03), (0.96, 0.03), (0.78, 0.20), (0.96, 0.20))
        case .laugh:
            b.ring(0.50, 0.50, 0.42)
            b.line((0.25, 0.45), (0.34, 0.36), (0.43, 0.45))  // eyes closed in a smile
            b.line((0.57, 0.45), (0.66, 0.36), (0.75, 0.45))
            var mouth = Path()
            mouth.move(to: CGPoint(x: 0.27, y: 0.56))
            mouth.addLine(to: CGPoint(x: 0.73, y: 0.56))
            mouth.addArc(center: CGPoint(x: 0.50, y: 0.56), radius: 0.23, startAngle: .degrees(0), endAngle: .degrees(180),
                         clockwise: false)
            mouth.closeSubpath()
            b.fill.addPath(mouth)
        case .cry:
            b.ring(0.50, 0.50, 0.42)
            b.line((0.25, 0.43), (0.40, 0.36))            // eyes pressed shut, slanting down outwards
            b.line((0.75, 0.43), (0.60, 0.36))
            b.drop(0.30, 0.64, 0.068)
            b.drop(0.70, 0.64, 0.068)
            b.arc(0.50, 0.80, 0.11, from: 200, to: 340)   // mouth turned down
        case .scream:
            b.ring(0.50, 0.50, 0.42)
            b.dot(0.34, 0.36, 0.055)
            b.dot(0.66, 0.36, 0.055)
            b.oval(0.50, 0.66, 0.13, 0.17)
        case .whistle:
            b.ring(0.38, 0.58, 0.34)
            b.dot(0.27, 0.50, 0.045)
            b.dot(0.47, 0.50, 0.045)
            b.oval(0.44, 0.72, 0.055, 0.055)
            b.oval(0.80, 0.34, 0.085, 0.065)              // note head
            b.line((0.875, 0.33), (0.875, 0.06), (0.97, 0.15))
        case .knock:
            var door = Path()
            door.addRoundedRect(in: CGRect(x: 0.44, y: 0.08, width: 0.46, height: 0.84),
                                cornerSize: CGSize(width: 0.05, height: 0.05))
            b.stroke.addPath(door)
            b.dot(0.79, 0.52, 0.05)
            b.line((0.31, 0.44), (0.10, 0.44))            // impact marks
            b.line((0.32, 0.29), (0.15, 0.17))
            b.line((0.32, 0.59), (0.15, 0.71))
        case .glassBreak:
            var pane = Path()
            pane.addRoundedRect(in: CGRect(x: 0.09, y: 0.09, width: 0.82, height: 0.82),
                                cornerSize: CGSize(width: 0.08, height: 0.08))
            b.stroke.addPath(pane)
            b.line((0.58, 0.09), (0.42, 0.36), (0.62, 0.50), (0.40, 0.91))  // a crack from edge to edge
            b.line((0.42, 0.36), (0.09, 0.28))                              // and its branches
            b.line((0.62, 0.50), (0.91, 0.62))
        }
    }
}
