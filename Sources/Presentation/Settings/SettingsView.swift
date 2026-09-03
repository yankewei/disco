import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var selectedSection: SettingsSection? = .providers
    @State private var hoveredSection: SettingsSection?
    @State private var lastScanAt: Date?

    fileprivate enum SettingsSection: String, CaseIterable, Identifiable, Equatable {
        case general
        case appearance
        case providers
        case skills
        case usage
        case daemons

        var id: Self {
            self
        }

        var title: String {
            switch self {
            case .general:
                "通用"
            case .appearance:
                "外观"
            case .providers:
                "服务商"
            case .skills:
                "技能"
            case .usage:
                "用量"
            case .daemons:
                "守护进程"
            }
        }

        var systemImage: String {
            switch self {
            case .general:
                "gearshape"
            case .appearance:
                "circle.lefthalf.filled"
            case .providers:
                "server.rack"
            case .skills:
                "cube"
            case .usage:
                "chart.bar"
            case .daemons:
                "rectangle.3.group"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Button {
                    dismiss()
                } label: {
                    Label("返回", systemImage: "chevron.left")
                        .font(DiscoTheme.Typography.body)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 10)

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(SettingsSection.allCases) { section in
                            Button {
                                selectedSection = section
                            } label: {
                                Label(section.title, systemImage: section.systemImage)
                                    .font(DiscoTheme.Typography.body)
                                    .foregroundStyle(section == selectedSection ? DiscoTheme.Palette.accent : .secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background {
                                        if section == selectedSection {
                                            RoundedRectangle(cornerRadius: DiscoTheme.Metrics.rowCornerRadius, style: .continuous)
                                                .fill(DiscoTheme.Palette.selection)
                                        } else if hoveredSection == section {
                                            RoundedRectangle(cornerRadius: DiscoTheme.Metrics.rowCornerRadius, style: .continuous)
                                                .fill(DiscoTheme.Palette.hover)
                                        }
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: DiscoTheme.Metrics.rowCornerRadius, style: .continuous))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { isHovering in
                                hoveredSection = isHovering ? section : nil
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityValue(section == selectedSection ? "已选中" : "")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                }
            }
            .frame(width: DiscoTheme.Metrics.sidebarWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(DiscoTheme.Palette.sidebar)

            Divider()

            Group {
                switch selectedSection ?? .providers {
                case .general:
                    GeneralSettingsView()
                case .providers:
                    ProviderSettingsView(
                        lastScanAt: lastScanAt,
                        onRefresh: { Task { await refreshProviders() } }
                    )
                case .appearance, .skills, .usage, .daemons:
                    SettingsPlaceholderView(section: selectedSection ?? .providers)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DiscoTheme.Palette.canvas)
        .font(DiscoTheme.Typography.body)
        .tint(DiscoTheme.Palette.accent)
        .task {
            await refreshProviders()
        }
    }

    private func refreshProviders() async {
        await model.refresh()
        lastScanAt = .now
    }
}

private struct ProviderSettingsView: View {
    @EnvironmentObject private var model: AppModel
    let lastScanAt: Date?
    let onRefresh: () -> Void

    var body: some View {
        SettingsPage {
            ProviderDirectoryCard(
                providers: model.providers,
                lastScanAt: lastScanAt,
                onRefresh: onRefresh,
                onUnavailableProviderTap: { provider in
                    model.workspaceError = "请安装 \(provider.kind.displayName) CLI，并确保命令在 PATH 中，然后点击“刷新”。"
                }
            )
        }
    }
}

private struct ProviderDirectoryCard: View {
    let providers: [ProviderInfo]
    let lastScanAt: Date?
    let onRefresh: () -> Void
    let onUnavailableProviderTap: (ProviderInfo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("编程智能体")
                        .font(DiscoTheme.Typography.sectionTitle)
                    Text("Disco 调用安装在这台电脑上的智能体命令行工具。请先安装相应工具或完成登录，然后刷新。")
                        .font(DiscoTheme.Typography.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 20)

                VStack(alignment: .trailing, spacing: 8) {
                    Button {
                        onRefresh()
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.regular)

                    Text(lastScanAt == nil ? "尚未检查" : "刚刚检查过")
                        .font(DiscoTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider()

            if providers.isEmpty {
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在扫描本机 CLI…")
                        .font(DiscoTheme.Typography.body)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            } else {
                ForEach(providers) { provider in
                    ProviderDirectoryRow(
                        provider: provider,
                        onUnavailableTap: onUnavailableProviderTap
                    )
                    if provider.id != providers.last?.id {
                        Divider()
                            .padding(.leading, 26)
                    }
                }
            }
        }
        .background(DiscoTheme.Palette.surface, in: RoundedRectangle(cornerRadius: DiscoTheme.Metrics.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DiscoTheme.Metrics.cardCornerRadius, style: .continuous)
                .stroke(DiscoTheme.Palette.border, lineWidth: 1)
        }
    }
}

private struct ProviderDirectoryRow: View {
    let provider: ProviderInfo
    let onUnavailableTap: (ProviderInfo) -> Void
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if provider.available, !provider.models.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    ProviderRowLabel(provider: provider, isExpanded: isExpanded)
                }
                .buttonStyle(.plain)
            } else if provider.available {
                ProviderRowLabel(provider: provider, isExpanded: false)
            } else {
                Button {
                    onUnavailableTap(provider)
                } label: {
                    ProviderRowLabel(provider: provider, isExpanded: false)
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(provider.models) { model in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(model.name)
                                .font(DiscoTheme.Typography.body)
                            Spacer(minLength: 12)
                            Text(model.id)
                                .font(DiscoTheme.Typography.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                .padding(.leading, 70)
                .padding(.trailing, 22)
                .padding(.bottom, 14)
            }
        }
    }
}

private struct ProviderRowLabel: View {
    let provider: ProviderInfo
    let isExpanded: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 14) {
            ProviderIcon(provider: provider)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(provider.kind.displayName)
                        .font(DiscoTheme.Typography.bodyEmphasized)
                        .foregroundStyle(provider.available ? .primary : .secondary)
                    if let version = versionLabel {
                        Text(version)
                            .font(DiscoTheme.Typography.code)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 7) {
                    if provider.available {
                        Text(compactExecutablePath)
                        if !provider.models.isEmpty {
                            Text("·")
                            Text("\(provider.models.count) 个模型")
                        }
                    } else {
                        Text(provider.detail)
                    }
                }
                .font(DiscoTheme.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 16)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isExpanded ? DiscoTheme.Palette.accent : .secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 11)
        .background(isHovering ? DiscoTheme.Palette.hover : .clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private var versionLabel: String? {
        provider.version?.split(separator: " ").last.map(String.init)
    }

    private var compactExecutablePath: String {
        guard let path = provider.executablePath else { return "路径未知" }
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(homePath) else { return path }
        return "~" + path.dropFirst(homePath.count)
    }
}

private struct ProviderIcon: View {
    let provider: ProviderInfo

    var body: some View {
        Image(provider.kind.iconAssetName)
            .resizable()
            .scaledToFit()
            .frame(width: 28, height: 28)
            .frame(width: 36, height: 36)
            .background(DiscoTheme.Palette.canvas)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(provider.available ? 1 : 0.45)
            .overlay(alignment: .bottomTrailing) {
                if provider.available {
                    Circle()
                        .fill(DiscoTheme.Palette.successIndicator)
                        .frame(width: 8, height: 8)
                        .overlay {
                            Circle()
                                .stroke(DiscoTheme.Palette.surface, lineWidth: 2)
                        }
                        .offset(x: 2, y: 2)
                }
            }
            .accessibilityHidden(true)
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "通用",
                subtitle: "查看 Disco 的本地数据与应用信息"
            )

            SettingsSectionTitle("应用")
            SettingsCard {
                SettingsValueRow(title: "版本", value: "原生 v1")
                Divider()
                SettingsValueRow(title: "系统要求", value: "macOS 14 或更高")
            }

            SettingsSectionTitle("数据")
            SettingsCard {
                SettingsValueRow(
                    title: "数据库",
                    value: model.databaseURL?.path ?? "不可用",
                    allowsTextSelection: true
                )
            }
        }
    }
}

private struct SettingsPlaceholderView: View {
    let section: SettingsView.SettingsSection

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: section.title,
                subtitle: "这个设置模块正在准备中"
            )
        }
    }
}

private struct SettingsPageHeader: View {
    let title: String
    let subtitle: String?

    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(DiscoTheme.Typography.pageTitle)
                .foregroundStyle(.primary)
            if let subtitle {
                Text(subtitle)
                    .font(DiscoTheme.Typography.body)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SettingsSectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(DiscoTheme.Typography.sectionTitle)
            .foregroundStyle(.primary)
    }
}

private struct SettingsValueRow: View {
    let title: String
    let value: String
    var allowsTextSelection = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(title)
                .font(DiscoTheme.Typography.body)
                .foregroundStyle(.primary)
            Spacer(minLength: 16)
            Group {
                if allowsTextSelection {
                    Text(value)
                        .textSelection(.enabled)
                } else {
                    Text(value)
                }
            }
            .font(DiscoTheme.Typography.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }
}

private struct SettingsCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(DiscoTheme.Palette.surface, in: RoundedRectangle(cornerRadius: DiscoTheme.Metrics.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DiscoTheme.Metrics.cardCornerRadius, style: .continuous)
                .stroke(DiscoTheme.Palette.border, lineWidth: 1)
        }
    }
}

private struct SettingsPage<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .frame(maxWidth: 1028, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 40)
            .padding(.top, 20)
            .padding(.bottom, 28)
        }
        .background(DiscoTheme.Palette.canvas)
    }
}
