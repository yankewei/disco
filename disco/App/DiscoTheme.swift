import AppKit
import SwiftUI

enum DiscoTheme {
    /// 主强调色：柔和蓝灰，用于品牌、模型选择与主要操作。
    static let accent = Color("AccentColor")
    /// 推理功能的低饱和梅紫色，与模型入口形成稳定区分，并随系统明暗模式适配。
    static let reasoningAccent = Color("ReasoningAccent")
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let elevatedSurface = Color(nsColor: .textBackgroundColor)
}

enum DiscoRadius {
    static let small: CGFloat = 8
    static let medium: CGFloat = 14
    static let large: CGFloat = 22
}

/// 动效统一配置（Apple 流体界面：弹簧可打断、继承速度；临界阻尼无过冲）
enum DiscoMotion {
    /// 用户手势驱动的展开/收起
    static let spring = Animation.spring(duration: 0.38, bounce: 0)
    /// 按钮按下反馈
    static let press = Animation.spring(duration: 0.28, bounce: 0)
}

struct DiscoMark: View {
    var size: CGFloat = 28
    var isActive = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !isActive || reduceMotion)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            let pulse = isActive && !reduceMotion ? 1 + sin(phase * 4.2) * 0.045 : 1

            // 使用独立图片资源，避免调试运行时回退成 macOS 通用应用图标。
            Image("AppLogo")
                .resizable()
                .renderingMode(.original)
                .interpolation(.high)
                .scaledToFit()
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
            .animation(DiscoMotion.press, value: configuration.isPressed)
    }
}

/// 列表行的选中/悬停高亮（统一各列表行的视觉反馈）
struct DiscoRowStyle: ViewModifier {
    let isSelected: Bool
    let isHovered: Bool

    private var rowBackground: Color {
        if isSelected { return DiscoTheme.accent.opacity(0.12) }
        if isHovered { return Color.primary.opacity(0.04) }
        return .clear
    }

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(rowBackground, in: RoundedRectangle(cornerRadius: DiscoRadius.small))
    }
}

extension View {
    /// 套用列表行选中/悬停高亮
    func discoRowStyle(isSelected: Bool, isHovered: Bool) -> some View {
        modifier(DiscoRowStyle(isSelected: isSelected, isHovered: isHovered))
    }
}

/// 服务商品牌图标：优先用品牌 logo 资源（Assets/BrandIcons），缺失时回退到 SF Symbol
struct VendorBrandIcon: View {
    let vendor: ProviderVendor
    /// 磁贴边长；为 nil 时不画磁贴（菜单 Label 等紧凑场景）
    var tileSize: CGFloat?
    /// 未选中/未开放时降透明显示
    var isActive = true

    /// 品牌 logo 尺寸：磁贴内约占 62%，无磁贴时按 14pt 基准
    private var brandSize: CGFloat { tileSize.map { $0 * 0.62 } ?? 14 }
    /// SF Symbol 尺寸：磁贴内约占 50%，无磁贴时按 13pt 基准
    private var symbolSize: CGFloat { tileSize.map { $0 * 0.5 } ?? 13 }

    var body: some View {
        if let brandIcon = vendor.brandIcon {
            Image(brandIcon)
                .resizable()
                .scaledToFit()
                .frame(width: brandSize, height: brandSize)
                .ifLet(tileSize) { content, size in
                    content
                        .frame(width: size, height: size)
                        .background(
                            Color.primary.opacity(0.055),
                            in: RoundedRectangle(cornerRadius: size * 0.28)
                        )
                }
                .opacity(isActive ? 1 : 0.45)
        } else {
            Image(systemName: vendor.icon)
                .font(.system(size: symbolSize, weight: .semibold))
                .foregroundStyle(isActive ? DiscoTheme.accent : Color.secondary)
                .ifLet(tileSize) { content, size in
                    content
                        .frame(width: size, height: size)
                        .background(
                            (isActive ? DiscoTheme.accent : Color.secondary).opacity(0.1),
                            in: RoundedRectangle(cornerRadius: size * 0.28)
                        )
                }
        }
    }
}

extension View {
    /// 可选值存在时应用变换，否则原样返回
    @ViewBuilder
    func ifLet<T, Content: View>(_ value: T?, @ViewBuilder transform: (Self, T) -> Content) -> some View {
        if let value {
            transform(self, value)
        } else {
            self
        }
    }
}
