#if canImport(UIKit) && !os(watchOS)
import SwiftUI
import UIKit

extension RGB {
    var color: Color { Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: 1) }
}

/// Corners rounded on some sides only (iOS 15 has no `UnevenRoundedRectangle`).
struct CMPCorners: Shape {
    var radius: CGFloat
    var corners: UIRectCorner

    @_optimize(size) func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius)).cgPath)
    }
}

/// Scruter's one-colour mark beside « Certifié par Scruter » and « Proposé par Scruter ».
struct CMPMark: Shape {
    @_optimize(size) func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        var p = Path()
        p.addArc(
            center: CGPoint(x: rect.minX + 12 * s, y: rect.minY + 12 * s), radius: 8 * s, startAngle: .degrees(-42.5),
            endAngle: .degrees(42.5), clockwise: true)
        return p
    }
}

/// The lower edge of the media (`hero.edge`, the web's `EDGES` in a 400 × 22 box), in the sheet's surface colour.
struct CMPEdge: Shape {
    var kind: String

    @_optimize(size) func path(in rect: CGRect) -> Path {
        let x = { (v: CGFloat) in rect.minX + v / 400 * rect.width }
        let y = { (v: CGFloat) in rect.minY + v / 22 * rect.height }
        var p = Path()
        switch kind {
        case "angle":
            p.move(to: CGPoint(x: x(0), y: y(22)))
            p.addLine(to: CGPoint(x: x(0), y: y(4)))
            p.addLine(to: CGPoint(x: x(400), y: y(18)))
            p.addLine(to: CGPoint(x: x(400), y: y(22)))
        case "straight":
            return p
        default:
            // M0 22V10C60 20 150 22 232 12S360 0 400 6V22Z
            p.move(to: CGPoint(x: x(0), y: y(22)))
            p.addLine(to: CGPoint(x: x(0), y: y(10)))
            p.addCurve(to: CGPoint(x: x(232), y: y(12)), control1: CGPoint(x: x(60), y: y(20)), control2: CGPoint(x: x(150), y: y(22)))
            p.addCurve(to: CGPoint(x: x(400), y: y(6)), control1: CGPoint(x: x(314), y: y(2)), control2: CGPoint(x: x(360), y: y(0)))
            p.addLine(to: CGPoint(x: x(400), y: y(22)))
        }
        p.closeSubpath()
        return p
    }
}

/// The rings of the tinted panel (a header without media).
struct CMPRings: View {
    let color: Color

    @_optimize(size) var body: some View {
        ZStack {
            ForEach(Array([104, 84, 62, 42, 22].enumerated()), id: \.offset) { i, r in
                Circle().stroke(color, lineWidth: i % 2 == 1 ? 6 : 2).frame(width: CGFloat(r * 2), height: CGFloat(r * 2))
            }
        }
        .frame(width: 220, height: 220)
        .opacity(0.22)
        .accessibilityHidden(true)
    }
}

/// A purpose's icon (SF Symbols for the catalogue's purposes; sliders for the customer's own).
enum CMPIcons {
    @_optimize(size) static func purpose(_ key: String) -> String {
        switch key {
        case "necessary": return "lock"
        case "analytics": return "chart.bar"
        case "embedded_content": return "play.rectangle"
        case "advertising": return "megaphone"
        case "personalization": return "sparkles"
        case "social_media": return "person.2"
        case "functional": return "gearshape"
        default: return "slider.horizontal.3"
        }
    }
}

/// The joined row « Tout refuser | Personnaliser | Tout accepter » (docs/CMP.md §4.5): equal columns at the
/// subheadline style, else the footnote style, else one joined column in the same order (large text sizes).
struct CMPButtonRow: View {
    struct Item {
        var title: String
        var primary: Bool
        var id: String
        var action: () -> Void
    }

    let items: [Item]
    let palette: Palette
    /// The width the row gets, to choose its layout.
    let width: CGFloat
    @Environment(\.dynamicTypeSize) private var typeSize

    private enum Mode { case row, small, column }

    private var mode: Mode {
        let columns = CGFloat(items.count)
        let room = (width - columns + 1) / columns - 12
        @_optimize(size) func fits(_ style: UIFont.TextStyle) -> Bool {
            let font = CMPButtonRow.font(style, typeSize)
            return items.allSatisfy { ($0.title as NSString).size(withAttributes: [.font: font]).width <= room }
        }
        if fits(.subheadline) { return .row }
        if fits(.footnote) { return .small }
        return .column
    }

    @_optimize(size) static func font(_ style: UIFont.TextStyle, _ size: DynamicTypeSize) -> UIFont {
        let traits = UITraitCollection(preferredContentSizeCategory: size.category)
        let base = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
        return UIFont.systemFont(ofSize: base.pointSize, weight: .bold)
    }

    @_optimize(size) var body: some View {
        let m = mode
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Group {
            if m == .column {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                        if i > 0 { palette.line.color.frame(height: 1) }
                        button(item, font: .subheadline)
                    }
                }
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                        if i > 0 { palette.line.color.frame(width: 1) }
                        button(item, font: m == .row ? .subheadline : .footnote)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(palette.line.color, lineWidth: 1))
    }

    @_optimize(size) private func button(_ item: Item, font: Font) -> some View {
        Button(action: item.action) {
            Text(item.title)
                .font(font.weight(item.primary ? .bold : .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(mode == .column ? nil : 1)
                .foregroundColor(item.primary ? palette.onBrand.color : palette.text.color)
                .padding(.horizontal, 6)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(item.primary ? palette.brand.color : palette.surface.color)
                .overlay(
                    Group {
                        if item.primary && palette.brandEdge { Rectangle().strokeBorder(RGB.ink.color, lineWidth: 2) }
                    })
                .contentShape(Rectangle())
        }
        .buttonStyle(CMPPressStyle())
        .accessibilityIdentifier("scruter-cmp-" + item.id)
    }
}

struct CMPPressStyle: ButtonStyle {
    @_optimize(size) func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.82 : 1)
    }
}

extension DynamicTypeSize {
    var category: UIContentSizeCategory {
        switch self {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        @unknown default: return .large
        }
    }
}

/// The height of a view's content, to size a scroll view to it.
struct CMPHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    @_optimize(size) static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The heights of the band and of the buttons, summed.
struct CMPChromeKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    @_optimize(size) static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

extension View {
    @_optimize(size) func cmpMeasureChrome() -> some View {
        background(GeometryReader { Color.clear.preference(key: CMPChromeKey.self, value: $0.size.height) })
    }

    @_optimize(size) func cmpMeasureHeight() -> some View {
        background(GeometryReader { Color.clear.preference(key: CMPHeightKey.self, value: $0.size.height) })
    }
}
#endif
