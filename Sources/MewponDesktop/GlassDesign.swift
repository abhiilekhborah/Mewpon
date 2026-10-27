import AppKit
import SwiftUI

enum MewponDesign {
    static let accent = Color.accentColor
    static let panelWidth: CGFloat = 460
    static let commandWidth: CGFloat = 600
    static let body = Font.system(size: 14)
    static let secondary = Font.system(size: 12)
    static let caption = Font.system(size: 11)
    static let radius: CGFloat = 18
    static let spacing: CGFloat = 8
}

struct CompanionGlass: ViewModifier {
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat = 18
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage("solidSurfaces") private var solidSurfaces = false
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let tokens = theme.current.palette(dark: scheme == .dark)
        let opaque = !theme.current.glass || reduceTransparency || solidSurfaces || contrast == .increased
        // Only the background changes identity. Keep content (native editor,
        // selection, and focus) mounted while switching glass/solid themes.
        content.background {
            if opaque { shape.fill(tokens.color(tokens.background)) }
            else if #available(macOS 26.0, *) { shape.fill(Color.clear).glassEffect(.regular, in: shape) }
            else { shape.fill(.regularMaterial) }
        }.overlay(shape.strokeBorder(tokens.color(tokens.border).opacity(contrast == .increased ? 0.6 : 0.18), lineWidth: contrast == .increased ? 1 : 0.5).allowsHitTesting(false))
    }
}
extension View {
    func companionGlass(radius: CGFloat = 18) -> some View { modifier(CompanionGlass(radius: radius)) }
}
