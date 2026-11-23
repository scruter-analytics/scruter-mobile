import Foundation

/// An sRGB colour, 0–255 per channel.
struct RGB: Equatable {
    var r: Int
    var g: Int
    var b: Int

    static let white = RGB(r: 255, g: 255, b: 255)
    /// Scruter's ink, the labels' dark colour (`INK`).
    static let ink = RGB(hex: "#17131F")!
    /// The banners' dark surface (`DARK_BG`).
    static let darkSurface = RGB(hex: "#1E1A27")!
    /// Scruter's violet, for a colour the configuration got wrong.
    static let violet = RGB(hex: "#6B4EFF")!

    @_optimize(size) init(r: Int, g: Int, b: Int) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// `#RRGGBB`.
    @_optimize(size) init?(hex: String) {
        guard hex.count == 7, hex.hasPrefix("#"), let n = Int(hex.dropFirst(), radix: 16) else { return nil }
        self.init(r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255)
    }

    var hex: String {
        "#" + [r, g, b].map { v in
            let s = String(v, radix: 16, uppercase: true)
            return s.count == 1 ? "0" + s : s
        }.joined()
    }

    @_optimize(size) private static func channel(_ v: Int) -> Double {
        let x = Double(v) / 255
        return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }

    /// WCAG relative luminance.
    var luminance: Double { 0.2126 * RGB.channel(r) + 0.7152 * RGB.channel(g) + 0.0722 * RGB.channel(b) }

    @_optimize(size) func contrast(_ o: RGB) -> Double {
        let x = luminance
        let y = o.luminance
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// White or ink on this colour, whichever contrasts more (`onColor`).
    var onColor: RGB { contrast(.white) >= contrast(.ink) ? .white : .ink }

    /// Darkened (white text) or lightened (ink text) in small steps until its text contrasts `min`:1, hue kept
    /// (`cmp/src/ui/style.ts` `strengthen`).
    @_optimize(size) func strengthened(_ min: Double) -> RGB {
        var c = self
        var i = 0
        while i < 40 && c.contrast(c.onColor) < min {
            let to = c.onColor == .white ? 0.0 : 255.0
            @_optimize(size) func ch(_ v: Int) -> Int { Int((Double(v) * 0.92 + to * 0.08).rounded()) }
            c = RGB(r: ch(c.r), g: ch(c.g), b: ch(c.b))
            i += 1
        }
        return c
    }

    /// `share` of this colour mixed into `o`.
    @_optimize(size) func mixed(into o: RGB, share: Double) -> RGB {
        @_optimize(size) func m(_ a: Int, _ b: Int) -> Int { Int((Double(a) * share + Double(b) * (1 - share)).rounded()) }
        return RGB(r: m(r, o.r), g: m(g, o.g), b: m(b, o.b))
    }

    /// The brand colour on the dark theme (docs/CMP.md §4.5, `cmp/src/shared/color.ts` `darkBrand`): itself where it
    /// reaches 3:1 against the dark surface; else the same hue and saturation, lightened until it does with white or
    /// ink at 4.5:1 on it; white for a hueless ink.
    var darkBrand: RGB {
        if contrast(.darkSurface) >= 3 { return self }
        let rr = Double(r) / 255, gg = Double(g) / 255, bb = Double(b) / 255
        let mx = max(rr, gg, bb)
        let d = mx - min(rr, gg, bb)
        if d < 0.1 { return .white }
        var l = mx - d / 2
        let s = d / (1 - abs(2 * l - 1))
        let h: Double =
            mx == rr ? ((gg - bb) / d + 6).truncatingRemainder(dividingBy: 6) : mx == gg ? (bb - rr) / d + 2 : (rr - gg) / d + 4
        while l < 1 {
            let k = (1 - abs(2 * l - 1)) * s
            let x = k * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
            let sectors: [[Double]] = [[k, x, 0], [x, k, 0], [0, k, x], [0, x, k], [x, 0, k], [k, 0, x]]
            let v = sectors[Int(h.rounded(.down)) % 6].map { Int((($0 + l - k / 2) * 255).rounded()) }
            let q = RGB(r: v[0], g: v[1], b: v[2])
            if q.contrast(.darkSurface) >= 3 && q.contrast(q.onColor) >= 4.5 { return q }
            l += 0.01
        }
        return .white
    }
}

/// The sheet's colours for one theme (the « Scruter v2 » card's, docs/CMP.md §4.5; board M3 for the dark theme).
struct Palette: Equatable {
    var dark: Bool
    /// The brand colour: « Tout accepter », the header band, the switches.
    var brand: RGB
    /// Labels on `brand`.
    var onBrand: RGB
    /// An ink edge on a light-theme fill under 3:1 against white.
    var brandEdge: Bool
    var surface: RGB
    var text: RGB
    var secondary: RGB
    var line: RGB
    var soft: RGB
    /// The kicker and the step icons: the brand colour where it reads at 4.5:1, else the text colour.
    var accent: RGB
    /// The tinted panel without media: 14 % of the brand colour.
    var tint: RGB

    /// `min`: the contrast of the primary buttons' text (5 with the IAB TCF, TCF Policies Appendix B C(g); the console
    /// asks 4.5), reached by `strengthened` as the site script's `strengthen` does.
    @_optimize(size) static func make(color: String, dark: Bool, min: Double = 0) -> Palette {
        let base = RGB(hex: color) ?? .violet
        if dark {
            let brand = base.darkBrand.strengthened(min)
            let surface = RGB.darkSurface
            return Palette(
                dark: true, brand: brand, onBrand: brand.onColor, brandEdge: false, surface: surface,
                text: RGB(hex: "#F4F2F8")!, secondary: RGB(hex: "#C9C4D4")!, line: RGB(hex: "#3A3545")!,
                soft: RGB(hex: "#2A2631")!, accent: base.contrast(surface) >= 4.5 ? base : .white,
                tint: base.mixed(into: surface, share: 0.14))
        }
        let brand = base.strengthened(min)
        return Palette(
            dark: false, brand: brand, onBrand: brand.onColor, brandEdge: brand.contrast(.white) < 3, surface: .white,
            text: .ink, secondary: RGB(hex: "#4D4859")!, line: RGB(hex: "#E7E3EE")!, soft: RGB(hex: "#F5F2EF")!,
            accent: base.contrast(.white) >= 4.5 ? base : .ink, tint: base.mixed(into: .white, share: 0.14))
    }
}
