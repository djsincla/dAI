import AppKit
import SwiftUI

/// Light, dark, or whatever the system is doing.
///
/// **Applied through `NSApp.appearance`, not `preferredColorScheme`.**
///
/// The palette is built from `NSColor(name:dynamicProvider:)`, which resolves
/// against the AppKit appearance. SwiftUI's `preferredColorScheme` sets an
/// environment value that its own views honour, and leaves every AppKit-backed
/// surface behind: the PDF viewer, the sidebar material, the scroll bars and
/// every colour in `Palette`. A window whose prose went dark while its sidebar
/// stayed light would be worse than having no setting at all.
///
/// Setting the application appearance moves all of it together, because it is
/// the thing all of it is already reading.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    private var nsAppearance: NSAppearance? {
        switch self {
        // nil hands the decision back to the system, which is not the same as
        // choosing light: a machine that switches at sunset should take this
        // window with it.
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    func apply() {
        NSApp?.appearance = nsAppearance
    }

    // ---------------------------------------------------------- persistence

    private static let key = "appearance"

    static var current: Appearance {
        get { Appearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "")
              ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            newValue.apply()
        }
    }

    /// The next one round the cycle, for the toolbar control.
    var next: Appearance {
        switch self {
        case .system: return .light
        case .light: return .dark
        case .dark: return .system
        }
    }
}

/// The toolbar control: one button that cycles, rather than a menu.
///
/// Three states is few enough that cycling is faster than choosing, and the
/// icon says which one you are in without being opened. The menu still exists
/// in Settings for somebody who wants to pick directly.
struct AppearanceButton: View {
    @Binding var appearance: Appearance

    var body: some View {
        Button {
            appearance = appearance.next
            Appearance.current = appearance
        } label: {
            Image(systemName: appearance.symbol)
        }
        .help("Appearance: \(appearance.label)")
        .accessibilityLabel("Appearance, currently \(appearance.label)")
    }
}
