import AppKit
import SwiftUI

enum DiscoTheme {
    static let coral = Color(red: 0.941, green: 0.353, blue: 0.388)
    static let amber = Color(red: 0.953, green: 0.604, blue: 0.345)
    static let plum = Color(red: 0.553, green: 0.353, blue: 0.784)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let elevatedSurface = Color(nsColor: .textBackgroundColor)
}

enum DiscoRadius {
    static let small: CGFloat = 8
    static let medium: CGFloat = 14
    static let large: CGFloat = 22
}

struct DiscoMark: View {
    var size: CGFloat = 28
    var isActive = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !isActive || reduceMotion)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            let pulse = isActive && !reduceMotion ? 1 + sin(phase * 4.2) * 0.045 : 1

            Circle()
                .fill(
                    AngularGradient(
                        colors: [
                            DiscoTheme.coral,
                            DiscoTheme.amber,
                            DiscoTheme.plum,
                            DiscoTheme.coral,
                        ],
                        center: .center
                    )
                )
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.42), lineWidth: max(1, size * 0.035))
                        .padding(max(1, size * 0.07))
                }
                .shadow(color: DiscoTheme.coral.opacity(isActive ? 0.34 : 0.18), radius: size * 0.22)
                .scaleEffect(pulse)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct DiscoPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
