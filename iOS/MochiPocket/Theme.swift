import SwiftUI

/// Mochi Pocket's design system, from a UI/UX Pro Max review (2026-11-04). The look is soft "claymorphism": chunky,
/// rounded cards on a warm cream backdrop with a hairline rim and a gentle double shadow. The rules behind it:
/// - Text is at least 4.5:1 against what it sits on. Mochi's peach (`peach`) is only for fills and glows; text, icons
///   and filled buttons use terracotta (`tint`), and secondary text uses a warm grey instead of the system's.
/// - Text uses Dynamic Type styles in SF Rounded, so it grows with the user's text size.
/// - Every control has a 44-point touch area, gives feedback when pressed, and has a spoken name.
/// - Motion respects Reduce Motion.
enum Theme {
    // MARK: Colour (contrast measured on `surface`)

    /// Primary text: 15:1.
    static let ink = Color(hex: 0x2B2118)
    /// Secondary text: 5.8:1 (the system grey is about 3.4:1 here).
    static let inkSecondary = Color(hex: 0x6E6259)
    /// Mochi's peach, for fills, glows and art; never small text (2.4:1).
    static let peach = MochiStyle.accent
    /// Terracotta for text, icons and filled buttons: 5.3:1, and white text on it is 5.4:1.
    static let tint = Color(hex: 0xB4471C)
    static let success = Color(hex: 0x1F7A4A)
    static let warning = Color(hex: 0xB45309)
    static let danger = Color(hex: 0xB42318)
    /// The VIP star (an icon, so 3:1 is enough: 3.6:1).
    static let vip = Color(hex: 0xB7791F)
    static let indigo = Color(hex: 0x4F46E5)
    static let pet = Color(hex: 0xC2335A)
    static let play = Color(hex: 0x2F7D4F)

    static let backgroundTop = Color(hex: 0xFFF6EE)
    static let backgroundBottom = Color(hex: 0xFBE3D2)
    /// Cards.
    static let surface = Color(hex: 0xFFFCF8)
    /// Wells inside cards: fields, unselected chips, round buttons.
    static let sunken = Color(hex: 0xF6ECE3)
    static let stroke = Color(hex: 0xEFDCCB)
    static let shadow = Color(hex: 0x7A4A2A)

    // MARK: Space, shape, touch

    /// An 8-point rhythm.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let card: CGFloat = 26
        static let inner: CGFloat = 16
        static let tile: CGFloat = 10
    }

    /// Apple's minimum touch target.
    static let touch: CGFloat = 44
}

extension Font {
    /// SF Rounded at a Dynamic Type text style, in the style's own weight unless `weight` says otherwise.
    static func mochi(_ style: Font.TextStyle, _ weight: Font.Weight? = nil) -> Font {
        guard let weight else { return .system(style, design: .rounded) }
        return .system(style, design: .rounded, weight: weight)
    }
}

// MARK: Surfaces

/// The clay surface behind a card: solid warm white, a hairline rim lit from above, and a soft shadow plus a contact
/// shadow.
struct ClaySurface: View {
    var radius: CGFloat = Theme.Radius.card
    var fill: Color = Theme.surface

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape.fill(fill)
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white, Theme.stroke], startPoint: .top, endPoint: .bottom),
                                        lineWidth: 1))
            .shadow(color: Theme.shadow.opacity(0.10), radius: 16, y: 8)
            .shadow(color: Theme.shadow.opacity(0.06), radius: 1.5, y: 1)
    }
}

extension View {
    /// A Mochi card: content padded on the clay surface, full width.
    func mochiCard(padding: CGFloat = Theme.Space.l) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ClaySurface())
    }
}

/// The app's warm backdrop, with a soft peach glow behind the top of the screen.
struct PocketBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.backgroundTop, Theme.backgroundBottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Theme.peach.opacity(0.18), .clear], center: .topTrailing, startRadius: 10, endRadius: 420)
        }
        .ignoresSafeArea()
    }
}

// MARK: Controls

/// A soft press for tappable tiles and buttons: a slight squish (just a dim with Reduce Motion), quick to respond.
struct ClayPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(reduceMotion ? nil : .spring(duration: 0.18, bounce: 0.3), value: configuration.isPressed)
    }
}

/// A round icon button: a 40-point disc inside a 44-point touch area, with a spoken name.
struct RoundIconButton: View {
    let symbol: String
    let label: String
    var tint: Color = Theme.tint
    /// Filled with the tint (for an "on" state, like while Mochi is reading).
    var prominent = false
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 40

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.mochi(.body, .semibold))
                .foregroundStyle(prominent ? Color.white : tint)
                .frame(width: size, height: size)
                .background(Circle().fill(prominent ? tint : Theme.sunken))
                .frame(minWidth: Theme.touch, minHeight: Theme.touch)
                .contentShape(Rectangle())
        }
        .buttonStyle(ClayPressStyle())
        .accessibilityLabel(label)
    }
}

/// A choice chip: terracotta when chosen, a sunken well otherwise, and a 44-point touch area.
struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.mochi(.subheadline, .semibold))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                .background(Capsule().fill(selected ? Theme.tint : Theme.sunken))
                .foregroundStyle(selected ? Color.white : Theme.ink)
                .frame(minHeight: Theme.touch)
                .contentShape(Rectangle())
        }
        .buttonStyle(ClayPressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: selected) { _, now in now }
    }
}

/// A small rounded tile with a filled symbol: the one icon style for list rows and card headers. Decorative (the text
/// beside it says the same), so VoiceOver skips it.
struct IconTile: View {
    let symbol: String
    let tint: Color
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).fill(tint.opacity(0.12)))
            .accessibilityHidden(true)
    }
}

/// A small status tag: tinted text on a faint wash of the same colour (4.5:1 or better).
struct Tag: View {
    let text: String
    var symbol: String?
    var tint: Color = Theme.tint

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
            Text(text)
        }
        .font(.mochi(.caption, .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.09)))
    }
}

/// A section title over the cards, with an optional note on the right.
struct SectionTitle: View {
    let title: String
    var note: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.mochi(.title3, .bold)).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let note { Text(note).font(.mochi(.footnote, .semibold)).foregroundStyle(Theme.inkSecondary) }
        }
        .padding(.horizontal, Theme.Space.xs)
        .padding(.top, Theme.Space.s)
    }
}
