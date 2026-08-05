import SwiftUI

struct SettingsView: View {
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

    private var filteredModels: [String] {
        let query = modelSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return models }
        return models.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var canLoadModels: Bool {
        !status.isLoading
            && !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.hasAPIKey)
    }

    private var canSave: Bool {
        !selectedModel.isEmpty
            && !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.hasAPIKey)
    }

    var body: some View {
        ZStack {
            DiscoTheme.canvas
                .ignoresSafeArea()

            VStack(spacing: 0) {
                settingsHeader

                Divider()
                    .opacity(0.65)

                VStack(spacing: 26) {
                    connectionSection
                    modelSection
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)

                Divider()
                    .opacity(0.65)

                settingsFooter
            }
        }
        .frame(width: 700, height: 680)
        .onAppear {
            guard baseURL.isEmpty else { return }
            baseURL = appState.baseURL
            selectedModel = appState.model
            models = appState.model.isEmpty ? [] : [appState.model]
            status = appState.hasAPIKey ? .current : .idle
            focusedField = appState.hasAPIKey ? nil : .apiKey
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
            "删除已保存的 API Key？",
            isPresented: $isConfirmingKeyDeletion,
            titleVisibility: .visible
        ) {
            Button("从 Keychain 删除", role: .destructive) {
                deleteAPIKey()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后需要重新输入 API Key 才能继续对话。")
        }
    }

    private var settingsHeader: some View {
        HStack(spacing: 14) {
            DiscoMark(size: 38, isActive: status.isLoading)

            VStack(alignment: .leading, spacing: 3) {
                Text("连接模型")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))

                Text("配置一个 OpenAI 兼容 API 服务")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 7) {
                Circle()
                    .fill(appState.hasAPIKey ? DiscoTheme.coral : Color.secondary.opacity(0.45))
                    .frame(width: 7, height: 7)
                Text(appState.hasAPIKey ? "已保存配置" : "尚未配置")
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("服务连接")
                    .font(.headline)
                Text("API Key 会发送到你填写的地址，请确认服务可信。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                SettingInputRow(icon: "network", title: "Base URL") {
                    TextField("https://api.openai.com/v1", text: $baseURL)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .baseURL)
                        .accessibilityLabel("Base URL")
                }

                Divider()
                    .padding(.leading, 54)

                SettingInputRow(icon: "key.fill", title: "API Key") {
                    SecureField(
                        appState.hasAPIKey ? "已保存在 Keychain，留空继续使用" : "输入 API Key",
                        text: $apiKey
                    )
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .apiKey)
                    .accessibilityLabel("API Key")
                }
            }
            .background(DiscoTheme.surface, in: RoundedRectangle(cornerRadius: DiscoRadius.medium))
            .shadow(color: .black.opacity(0.07), radius: 8, y: 2)

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
                    .background(DiscoTheme.coral, in: Capsule())
                }
                .buttonStyle(DiscoPressButtonStyle())
                .disabled(!canLoadModels)
                .opacity(canLoadModels || status.isLoading ? 1 : 0.4)
            }
            .frame(minHeight: 38)
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
            StatusLabel(icon: "trash", text: "API Key 已从 Keychain 删除", color: .secondary)
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("选择模型")
                        .font(.headline)

                    if models.isEmpty {
                        Text("连接后会列出服务返回的全部模型")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(status.isLoaded ? "\(models.count) 个可用模型" : "当前模型")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

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

            Group {
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
            }
            .frame(height: 225)
            .background(DiscoTheme.surface, in: RoundedRectangle(cornerRadius: DiscoRadius.medium))
            .clipShape(RoundedRectangle(cornerRadius: DiscoRadius.medium))
            .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
        }
    }

    private var settingsFooter: some View {
        HStack(spacing: 12) {
            Image(systemName: appState.hasAPIKey ? "lock.fill" : "lock.open")
                .foregroundStyle(appState.hasAPIKey ? DiscoTheme.coral : .secondary)

            Text(appState.hasAPIKey ? "API Key 已保存在 Keychain" : "API Key 尚未保存")
                .font(.caption)
                .foregroundStyle(.secondary)

            if appState.hasAPIKey {
                Button("删除 Key", role: .destructive) {
                    isConfirmingKeyDeletion = true
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
            }

            Spacer()

            Button {
                do {
                    try appState.saveConfiguration(
                        baseURL: baseURL,
                        apiKey: apiKey,
                        model: selectedModel
                    )
                    apiKey = ""
                    status = .saved
                } catch {
                    status = .failed(error.localizedDescription)
                }
            } label: {
                Text("保存配置")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(DiscoTheme.coral, in: Capsule())
            }
            .buttonStyle(DiscoPressButtonStyle())
            .disabled(!canSave)
            .opacity(canSave ? 1 : 0.4)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }

    private func deleteAPIKey() {
        do {
            try appState.deleteAPIKey()
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

    var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }
}

private struct SettingInputRow<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DiscoTheme.coral)
                .frame(width: 26, height: 26)
                .background(DiscoTheme.coral.opacity(0.1), in: RoundedRectangle(cornerRadius: DiscoRadius.small))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    .foregroundStyle(isSelected ? DiscoTheme.coral : Color.secondary.opacity(0.5))

                Text(model)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                if isSelected {
                    Text("已选择")
                        .font(.caption)
                        .foregroundStyle(DiscoTheme.coral)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 43)
            .contentShape(Rectangle())
            .background(
                isSelected
                    ? DiscoTheme.coral.opacity(0.1)
                    : (isHovered ? Color.primary.opacity(0.035) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(model)
        .accessibilityValue(isSelected ? "已选择" : "未选择")
    }
}
