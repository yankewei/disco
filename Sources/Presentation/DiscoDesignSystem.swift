import AppKit
import SwiftUI

enum DiscoTheme {
    enum Palette {
        static let canvas = dynamicColor(
            light: NSColor(calibratedRed: 0.930, green: 0.925, blue: 0.900, alpha: 1),
            dark: NSColor(calibratedRed: 0.105, green: 0.115, blue: 0.165, alpha: 1)
        )
        static let surface = dynamicColor(
            light: NSColor(calibratedRed: 0.985, green: 0.978, blue: 0.945, alpha: 1),
            dark: NSColor(calibratedRed: 0.135, green: 0.145, blue: 0.205, alpha: 1)
        )
        static let sidebar = dynamicColor(
            light: NSColor(calibratedRed: 0.900, green: 0.895, blue: 0.870, alpha: 1),
            dark: NSColor(calibratedRed: 0.125, green: 0.135, blue: 0.185, alpha: 1)
        )
        static let insetSurface = dynamicColor(
            light: NSColor(calibratedRed: 0.945, green: 0.938, blue: 0.905, alpha: 1),
            dark: NSColor(calibratedRed: 0.175, green: 0.185, blue: 0.245, alpha: 1)
        )
        static let accent = SwiftUI.Color(nsColor: NSColor(calibratedRed: 0.355, green: 0.286, blue: 0.510, alpha: 1))
        static let hover = SwiftUI.Color.primary.opacity(0.055)
        static let selection = accent.opacity(0.20)
        static let selectionStrong = accent.opacity(0.28)
        static let border = SwiftUI.Color.primary.opacity(0.13)
        static let controlSurface = SwiftUI.Color.primary.opacity(0.055)
        static let userMessageSurface = accent.opacity(0.14)
        static let warningSurface = SwiftUI.Color.orange.opacity(0.12)
        static let successIndicator = SwiftUI.Color.green

        private static func dynamicColor(light: NSColor, dark: NSColor) -> SwiftUI.Color {
            SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            })
        }
    }

    enum Typography {
        static let pageTitle = Font.system(size: 24, weight: .semibold)
        static let sectionTitle = Font.system(size: 15, weight: .semibold)
        static let body = Font.system(size: 14)
        static let bodyEmphasized = Font.system(size: 14, weight: .medium)
        static let messageLineSpacing: CGFloat = 6
        static let messageTracking: CGFloat = 0.08
        static let sidebar = Font.system(size: 13)
        static let sidebarHeading = Font.system(size: 13, weight: .semibold)
        static let control = Font.system(size: 12, weight: .medium)
        static let caption = Font.system(size: 11)
        static let captionEmphasized = Font.system(size: 11, weight: .semibold)
        static let code = Font.system(size: 12, design: .monospaced)
    }

    enum Metrics {
        static let sidebarWidth: CGFloat = 228
        static let rowCornerRadius: CGFloat = 7
        static let cardCornerRadius: CGFloat = 14
        static let composerCornerRadius: CGFloat = 16
    }
}
