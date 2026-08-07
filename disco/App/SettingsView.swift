import SwiftUI

// MARK: - 设置分区（侧边栏导航）

private enum SettingsSection: String, CaseIterable, Identifiable {
    case providers
    // 后续新增：case tools
    // 后续新增：case skills

    var id: String { rawValue }

    var title: String {
        switch self {
        case .providers: "Providers"
        }
    }

    var icon: String {
        switch self {
        case .providers: "server.rack"
        }
    }
}

// MARK: - 设置主视图

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selectedSection: SettingsSection = .providers
    @State private var expandedVendor: ProviderVendor? = .deepseek

    var body: some View {
        ZStack {
            DiscoTheme.canvas
                .ignoresSafeArea()

            HStack(spacing: 0) {
                sidebar

                Divider()
                    .opacity(0.65)

                content
            }
        }
        .frame(width: 880, height: 680)
    }

    // MARK: 侧边栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                DiscoMark(size: 30)

                VStack(alignment: .leading, spacing: 1) {
                    Text("disco")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("偏好设置")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 22)

            VStack(spacing: 2) {
                ForEach(SettingsSection.allCases) { section in
                    SidebarItemView(
                        section: section,
                        isSelected: selectedSection == section
                    ) {
                        selectedSection = section
                    }
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            HStack(spacing: 8) {
                Circle()
                    .fill(appState.hasAPIKey ? DiscoTheme.accent : Color.secondary.opacity(0.45))
                    .frame(width: 7, height: 7)
                Text(appState.hasAPIKey ? "已保存配置" : "尚未配置")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .frame(width: 210)
        .background(.ultraThinMaterial)
    }

    // MARK: 右侧内容

    private var content: some View {
        VStack(spacing: 0) {
            contentHeader

            Divider()
                .opacity(0.65)

            ScrollView {
                VStack(spacing: 26) {
                    providerSection
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
            }
        }
    }

    private var contentHeader: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(selectedSection.title)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text("配置服务商连接，选择当前使用的模型")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader(
                title: "模型服务商",
                caption: "展开并配置服务商，可配置多个；标记“使用中”的会驱动对话。"
            )

            VStack(spacing: 10) {
                ForEach(ProviderVendor.allCases) { vendor in
                    VendorCard(
                        vendor: vendor,
                        isActive: appState.activeVendor == vendor,
                        isExpanded: expandedVendor == vendor,
                        isConfigured: appState.config(for: vendor)?.hasAPIKey == true
                    ) {
                        guard vendor.isAvailable else { return }
                        withAnimation(reduceMotion ? nil : DiscoMotion.spring) {
                            expandedVendor = expandedVendor == vendor ? nil : vendor
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 服务商卡片（手风琴）

private struct VendorCard: View {
    let vendor: ProviderVendor
    let isActive: Bool
    let isExpanded: Bool
    let isConfigured: Bool
    let onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 14) {
                    Image(systemName: vendor.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(vendor.isAvailable ? DiscoTheme.accent : Color.secondary)
                        .frame(width: 34, height: 34)
                        .background(
                            (vendor.isAvailable ? DiscoTheme.accent : Color.secondary).opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 10)
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(vendor.title)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.primary)
                            if isConfigured {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.caption)
                                    .foregroundStyle(DiscoTheme.accent)
                            }
                        }
                        Text(vendor.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    if isActive {
                        Text("使用中")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(DiscoTheme.accent)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(DiscoTheme.accent.opacity(0.12), in: Capsule())
                    } else if !vendor.isAvailable {
                        Text("即将推出")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }

                    if vendor.isAvailable {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
                .background(
                    isHovered && vendor.isAvailable ? Color.primary.opacity(0.03) : Color.clear
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            if isExpanded {
                Divider()
                    .padding(.leading, 62)

                VendorConfigPanel(vendor: vendor)
                    .padding(16)
            }
        }
        .background(DiscoTheme.surface, in: RoundedRectangle(cornerRadius: DiscoRadius.medium))
        .clipShape(RoundedRectangle(cornerRadius: DiscoRadius.medium))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }
}

// MARK: - 单个服务商配置面板

private struct VendorConfigPanel: View {
    let vendor: ProviderVendor

    @EnvironmentObject private var appState: AppState

    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var models: [String] = []
    @State private var selectedModel = ""
    @State private var modelSearch = ""
    @State private var loadRequestID: UUID?
    @State private var status = ConfigurationStatus.idle
    @State private var isConfirmingKeyDeletion = false
    @FocusState private var focusedField: ConfigurationField?

    private var config: ProviderConfig? { appState.config(for: vendor) }

    private var filteredModels: [String] {
        let query = modelSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return models }
        return models.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var canLoadModels: Bool {
        !status.isLoading
            && !trimmedBaseURL.isEmpty
            && (!trimmedAPIKey.isEmpty || config?.hasAPIKey == true)
    }

    private var canSave: Bool {
        !selectedModel.isEmpty
            && !trimmedBaseURL.isEmpty
            && (!trimmedAPIKey.isEmpty || config?.hasAPIKey == true)
    }

    private var trimmedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 0) {
                SettingInputRow(icon: "network", title: "Base URL") {
                    TextField(vendor.defaultBaseURL.isEmpty ? "https://api.example.com/v1" : vendor.defaultBaseURL, text: $baseURL)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .baseURL)
                        .accessibilityLabel("Base URL")
                }

                Divider()
                    .padding(.leading, 54)

                SettingInputRow(icon: "key.fill", title: "API Key") {
                    SecureField(
                        (config?.hasAPIKey ?? false) ? "已保存，留空继续使用" : "输入 API Key",
                        text: $apiKey
                    )
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .apiKey)
                    .accessibilityLabel("API Key")
                }
            }

            HStack(spacing: 14) {
                configurationStatus

                Spacer(minLength: 12)

                Button {
                    loadRequestID = UUID()
                } label: {
                    HStack(spacing: 8) {
                        if status.isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text(status.isLoading ? "正在连接" : "连接并加载模型")
                    }
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 150)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(DiscoTheme.accent, in: Capsule())
                }
                .buttonStyle(DiscoPressButtonStyle())
                .disabled(!canLoadModels)
                .opacity(canLoadModels || status.isLoading ? 1 : 0.4)
            }
            .frame(minHeight: 38)

            modelList
                .frame(height: 180)

            SettingInputRow(icon: "brain", title: "思考模式", caption: "开启后该服务商的请求会先进行推理") {
                Toggle(
                    "思考模式",
                    isOn: Binding(
                        get: { appState.config(for: vendor)?.thinkingEnabled ?? true },
                        set: { appState.setThinkingEnabled($0, for: vendor) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("思考模式")
            }

            Divider()
                .opacity(0.65)

            HStack(spacing: 12) {
                if config?.hasAPIKey == true {
                    Button("删除 Key", role: .destructive) {
                        isConfirmingKeyDeletion = true
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
                }

                Spacer()

                if appState.activeVendor != vendor {
                    Button {
                        appState.setActiveVendor(vendor)
                    } label: {
                        Text(config?.isConfigured == true ? "设为当前服务商" : "当前未配置")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(DiscoTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(config?.isConfigured != true)
                }

                Button {
                    save()
                } label: {
                    Text("保存配置")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(DiscoTheme.accent, in: Capsule())
                }
                .buttonStyle(DiscoPressButtonStyle())
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.4)
            }
        }
        .onAppear {
            baseURL = config?.baseURL ?? vendor.defaultBaseURL
            selectedModel = config?.model ?? ""
            models = selectedModel.isEmpty ? [] : [selectedModel]
            status = (config?.hasAPIKey ?? false) ? .current : .idle
        }
        .onChange(of: baseURL) { oldValue, _ in
            guard !oldValue.isEmpty else { return }
            models = []
            selectedModel = ""
            modelSearch = ""
            status = .idle
        }
        .task(id: loadRequestID) {
            guard loadRequestID != nil else { return }
            status = .loading
            defer { loadRequestID = nil }

            do {
                let loadedModels = try await appState.availableModels(
                    vendor: vendor,
                    baseURL: baseURL,
                    apiKey: apiKey
                )
                guard !Task.isCancelled else { return }
                models = loadedModels
                modelSearch = ""
                if !loadedModels.contains(selectedModel) {
                    selectedModel = ""
                }
                status = .loaded(loadedModels.count)
            } catch is CancellationError {
                return
            } catch {
                models = []
                selectedModel = ""
                status = .failed(error.localizedDescription)
            }
        }
        .confirmationDialog(
            "删除 \(vendor.title) 已保存的 API Key？",
            isPresented: $isConfirmingKeyDeletion,
            titleVisibility: .visible
        ) {
            Button("删除已保存的 Key", role: .destructive) {
                deleteKey()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后需要重新输入 API Key 才能继续对话。")
        }
    }

    @ViewBuilder
    private var configurationStatus: some View {
        switch status {
        case .idle:
            StatusLabel(icon: "circle.dotted", text: "填写信息后连接服务", color: .secondary)
        case .current:
            StatusLabel(icon: "checkmark.circle", text: "当前配置可用，连接可刷新模型", color: .secondary)
        case .loading:
            StatusLabel(icon: "ellipsis", text: "正在读取服务模型", color: .secondary)
        case let .loaded(count):
            StatusLabel(icon: "checkmark.circle.fill", text: "已读取 \(count) 个模型", color: .green)
        case let .failed(message):
            StatusLabel(icon: "exclamationmark.circle.fill", text: message, color: .red)
                .help(message)
        case .saved:
            StatusLabel(icon: "checkmark.circle.fill", text: "配置已保存", color: .green)
        case .keyDeleted:
            StatusLabel(icon: "trash", text: "API Key 已删除", color: .secondary)
        }
    }

    @ViewBuilder
    private var modelList: some View {
        if status.isLoading {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 3) {
                    Text("正在加载模型")
                        .font(.callout.weight(.medium))
                    Text("这通常只需要几秒钟")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if models.isEmpty {
            HStack(spacing: 13) {
                Image(systemName: "square.stack.3d.up")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("还没有模型列表")
                        .font(.callout.weight(.medium))
                    Text("先完成上面的服务连接")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if filteredModels.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                Text("没有匹配“\(modelSearch)”的模型")
                    .font(.callout)
                Spacer()
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(spacing: 0) {
                HStack(alignment: .center) {
                    Text("选择模型")
                        .font(.headline)
                    Spacer()
                    if models.count > 7 {
                        HStack(spacing: 7) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("筛选模型", text: $modelSearch)
                                .textFieldStyle(.plain)
                                .frame(width: 150)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.quaternary, in: Capsule())
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredModels, id: \.self) { model in
                            ModelSelectionRow(
                                model: model,
                                isSelected: selectedModel == model
                            ) {
                                selectedModel = model
                                if status == .saved {
                                    status = .loaded(models.count)
                                }
                            }

                            if model != filteredModels.last {
                                Divider()
                                    .padding(.leading, 46)
                            }
                        }
                    }
                }
            }
            .background(DiscoTheme.surface, in: RoundedRectangle(cornerRadius: DiscoRadius.small))
            .clipShape(RoundedRectangle(cornerRadius: DiscoRadius.small))
        }
    }

    private func save() {
        do {
            try appState.saveProviderConfig(
                vendor: vendor,
                baseURL: baseURL,
                apiKey: apiKey,
                model: selectedModel,
                models: models
            )
            apiKey = ""
            status = .saved
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func deleteKey() {
        do {
            try appState.deleteProviderAPIKey(vendor: vendor)
            apiKey = ""
            models = []
            selectedModel = ""
            modelSearch = ""
            status = .keyDeleted
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}

// MARK: - 辅助控件

private enum ConfigurationField: Hashable {
    case baseURL
    case apiKey
}

private enum ConfigurationStatus: Equatable {
    case idle
    case current
    case loading
    case loaded(Int)
    case failed(String)
    case saved
    case keyDeleted

    var isLoading: Bool {
        self == .loading
    }
}

private struct SidebarItemView: View {
    let section: SettingsSection
    let isSelected: Bool
    let select: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 22)
                Text(section.title)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                isSelected
                    ? DiscoTheme.accent.opacity(0.12)
                    : (isHovered ? Color.primary.opacity(0.04) : Color.clear),
                in: RoundedRectangle(cornerRadius: DiscoRadius.small)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct SettingsSectionHeader: View {
    let title: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(DiscoTheme.surface, in: RoundedRectangle(cornerRadius: DiscoRadius.medium))
            .shadow(color: .black.opacity(0.07), radius: 8, y: 2)
    }
}

private struct SettingInputRow<Content: View>: View {
    let icon: String
    let title: String
    var caption: String?
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DiscoTheme.accent)
                .frame(width: 26, height: 26)
                .background(DiscoTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: DiscoRadius.small))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let caption {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                content
                    .font(.body)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

private struct StatusLabel: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        Label(text, systemImage: icon)
            .font(.callout)
            .foregroundStyle(color)
            .lineLimit(2)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

private struct ModelSelectionRow: View {
    let model: String
    let isSelected: Bool
    let select: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? DiscoTheme.accent : Color.secondary.opacity(0.5))

                Text(model)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                if isSelected {
                    Text("已选择")
                        .font(.caption)
                        .foregroundStyle(DiscoTheme.accent)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 43)
            .contentShape(Rectangle())
            .background(
                isSelected
                    ? DiscoTheme.accent.opacity(0.1)
                    : (isHovered ? Color.primary.opacity(0.035) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(model)
        .accessibilityValue(isSelected ? "已选择" : "未选择")
    }
}
