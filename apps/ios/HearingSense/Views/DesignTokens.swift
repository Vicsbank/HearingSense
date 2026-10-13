import SwiftUI

// The app's design tokens: one spacing scale, one set of sizes, one set of corner radii.
//
// These are the project's own values, chosen to sit well beside the system's components; they
// are not measurements from Apple's guidelines. What does come from the guidelines: text uses
// the semantic text styles only (San Francisco through the system font, Dynamic Type), nothing
// is smaller than the system's minimum of 11 pt, weights are Regular to Bold, and everything
// that can be touched is at least 44 by 44 points.

enum HSSpacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum HSLayout {
    /// Leading and trailing edge of every screen's own content.
    static let margin: CGFloat = HSSpacing.l
    /// Smallest size of anything that can be touched.
    static let minimumHitTarget: CGFloat = 44
    /// Height of the label inside a large button; with the system's padding the button is 52 pt.
    static let buttonLabelHeight: CGFloat = 28
    /// The circle behind the current sound's icon, and the icon in it at the default text size.
    static let heroDiameter: CGFloat = 184
    static let heroSymbol: CGFloat = 76
    static let heroSymbolLimit: CGFloat = 112
    static let statusDot: CGFloat = 8
}

enum HSRadius {
    static let card: CGFloat = 20
}
