#if os(macOS) && canImport(SwiftUI)
import SwiftUI

struct ScruterScreenModifier: ViewModifier {
    let name: String

    func body(content: Content) -> some View {
        content.onAppear { Scruter.screen(name) }
    }
}

/// The SwiftUI modifiers on a Mac. `scruterScreen` counts screens as on iOS; the others mark what a Mac does not
/// measure (taps, forms, screen images) and change nothing, so that one SwiftUI codebase builds for iOS and macOS.
extension View {
    /// Counts a screen view named `name` each time this view appears (SwiftUI screens have no automatic name).
    public func scruterScreen(_ name: String) -> some View {
        modifier(ScruterScreenModifier(name: name))
    }

    /// Taps and forms are not measured on a Mac: no effect there.
    public func scruterId(_ id: String, label: String? = nil) -> some View { self }

    /// Screen images are not taken on a Mac: no effect there.
    public func scruterMask() -> some View { self }

    /// Taps and forms are not measured on a Mac: no effect there.
    public func scruterIgnore() -> some View { self }

    /// Forms are not measured on a Mac: no effect there.
    public func scruterForm(_ name: String) -> some View { self }
}
#endif
