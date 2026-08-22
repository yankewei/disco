import SwiftUI

// MARK: - 设置分区（侧边栏导航，后续新增 tools / skills 等）

private enum SettingsSection: String, CaseIterable, Identifiable {
    case providers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .providers: "服务商"
        }
    }

    var icon: String {
        switch self {
        case .providers: "server.rack"
        }
    }
}

// MARK: - 设置主视图（左设置分类，右侧为分类内容）

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    @State private var selectedSection: SettingsSection = .providers
    @State private var selectedVendor: ProviderVendor?
    /// 各服务商未保存的输入草稿，切换服务商时不丢失
    @State private var drafts: [ProviderVendor: VendorDraft] = [:]

    /// 服务商页直接列出全部已可用的服务商，选中即可配置
    private var listedVendors: [ProviderVendor] {
        ProviderVendor.allCases.filter(\.isAvailable)
    }

    /// 尚未开放的服务商（列表底部置灰展示“即将推出”，保留规划可见性）
    private var upcomingVendors: [ProviderVendor] {
        ProviderVendor.allCases.filter { !$0.isAvailable }
    }

    var body: some View {
        HStack(spacing: 0) {
            sectionSidebar

            Divider()
                .opacity(0.65)

            sectionContent
        }
        .background(DiscoTheme.canvas.ignoresSafeArea())
        .frame(width: 940, height: 600)
        .onAppear {
            if selectedVendor == nil {
                selectedVendor = listedVendors.contains(appState.activeVendor)
                    ? appState.activeVendor
                    : listedVendors.first
            }
        }
    }

    // MARK: 左栏：设置分类

    private var sectionSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                DiscoMark(size: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text("disco")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("偏好设置")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 18)

            VStack(spacing: 2) {
                ForEach(SettingsSection.allCases) { section in
                    SettingsSectionRow(
                        section: section,
                        isSelected: selectedSection == section
                    ) {
                        selectedSection = section
                    }
                }
            }
            .padding(.horizontal, 8)

            Spacer()
        }
        .frame(width: 168)
        .background(.ultraThinMaterial)
    }

    // MARK: 右侧：分类内容

    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection {
        case .providers:
            HStack(spacing: 0) {
                vendorListColumn

                Divider()
                    .opacity(0.65)

                vendorDetailColumn
            }
        }
    }

    // MARK: 服务商页：服务商列表

    private var vendorListColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 2) {
                    ForEach(listedVendors) { vendor in
                        VendorListRow(
                            vendor: vendor,
                            status: connectionStatus(for: vendor),
                            model: appState.config(for: vendor)?.model ?? "",
                            isSelected: selectedVendor == vendor
                        ) {
                            selectedVendor = vendor
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 12)

                if !upcomingVendors.isEmpty {
                    Divider()
                        .opacity(0.65)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)

                    VStack(spacing: 2) {
                        ForEach(upcomingVendors) { vendor in
                            UpcomingVendorRow(vendor: vendor)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(width: 208)
    }

    // MARK: 服务商页：连接详情

    @ViewBuilder
    private var vendorDetailColumn: some View {
        if let vendor = selectedVendor, listedVendors.contains(vendor) {
            VendorDetailPanel(
                vendor: vendor,
                draft: draftBinding(for: vendor)
            )
            .id(vendor)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            DiscoMark(size: 46)

            VStack(spacing: 6) {
                Text("选择一个服务商")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Text("在左侧列表中选择一个服务商进行配置。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func draftBinding(for vendor: ProviderVendor) -> Binding<VendorDraft> {
        Binding(
            get: { drafts[vendor] ?? VendorDraft() },
            set: { drafts[vendor] = $0 }
        )
    }

    // MARK: 状态归纳

    private func connectionStatus(for vendor: ProviderVendor) -> ConnectionStatus {
        ConnectionStatus(vendor: vendor, config: appState.config(for: vendor))
    }
}

// MARK: - 连接状态

private enum ConnectionStatus {
    case verified
    case unverified
    case unconfigured

    init(vendor: ProviderVendor, config: ProviderConfig?) {
        guard let config, vendor.isConfigured(config) else {
            self = .unconfigured
            return
        }
        self = config.lastVerifiedAt != nil ? .verified : .unverified
    }

    var color: Color {
        switch self {
        case .verified: .green
        case .unverified: .orange
        case .unconfigured: Color.secondary.opacity(0.45)
        }
    }

    var title: String {
        switch self {
        case .verified: "已连接"
        case .unverified: "未验证"
        case .unconfigured: "未配置"
        }
    }
}

// MARK: - 服务商草稿（未验证保存的输入）

private struct VendorDraft: Equatable {
    var baseURL = ""
    var apiKey = ""
    var isKeyVisible = false
    var models: [String] = []
    var selectedModel = ""
    var modelSearch = ""
}

// MARK: - 凭据指纹与校验门（纯值逻辑，便于单元测试）

/// 凭据指纹：归一化 Base URL + API Key，用于判定“当前输入是否已通过验证”
struct CredentialFingerprint: Equatable {
    var baseURL: String
    var apiKey: String
}

/// 服务商编辑面板的校验门：决定模型选择是否可用（纯逻辑，无 UI 依赖）
struct VendorEditGate {
    /// 已保存配置的 baseURL（nil 表示从未配置）
    var savedBaseURL: String?
    /// 当前草稿输入
    var draftBaseURL: String
    var draftAPIKey: String
    /// 是否已加载模型列表
    var hasLoadedModels: Bool
    /// 最近一次验证通过的凭据指纹
    var verifiedFingerprint: CredentialFingerprint?

    private var trimmedAPIKey: String {
        draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 与保存配置时一致的 baseURL 归一化（去尾部斜杠）
    private var normalizedBaseURL: String {
        var value = draftBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// 当前输入对应的凭据指纹
    var currentFingerprint: CredentialFingerprint {
        CredentialFingerprint(baseURL: normalizedBaseURL, apiKey: trimmedAPIKey)
    }

    /// 草稿输入与已保存配置不一致（改了 URL 或输入了新 Key）
    private var inputDiffersFromSaved: Bool {
        if trimmedAPIKey.isEmpty, let savedBaseURL {
            return normalizedBaseURL != savedBaseURL
        }
        return true
    }

    /// 模型列表是否可选择（选择即保存）
    var canSelectModel: Bool {
        guard hasLoadedModels else { return false }
        if inputDiffersFromSaved { return verifiedFingerprint == currentFingerprint }
        return true
    }
}

// MARK: - 设置分类行

private struct SettingsSectionRow: View {
    let section: SettingsSection
    let isSelected: Bool
    let select: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 22)
                Text(section.title)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .discoRowStyle(isSelected: isSelected, isHovered: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - 左栏服务商行

private struct VendorListRow: View {
    let vendor: ProviderVendor
    let status: ConnectionStatus
    let model: String
    let isSelected: Bool
    let select: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                VendorBrandIcon(vendor: vendor, tileSize: 26, isActive: isSelected)

                VStack(alignment: .leading, spacing: 2) {
                    Text(vendor.title)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(model.isEmpty ? status.title : model)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)

                Circle()
                    .fill(status.color)
                    .frame(width: 7, height: 7)
                    .help(status.title)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .discoRowStyle(isSelected: isSelected, isHovered: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - 左栏“即将推出”服务商行（不可点击）

private struct UpcomingVendorRow: View {
    let vendor: ProviderVendor

    var body: some View {
        HStack(spacing: 10) {
            VendorBrandIcon(vendor: vendor, tileSize: 26, isActive: false)

            VStack(alignment: .leading, spacing: 2) {
                Text(vendor.title)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("即将推出")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .opacity(0.55)
    }
}

// MARK: - 单个服务商详情面板

private struct VendorDetailPanel: View {
    /// 验证时间的中文相对格式（系统 locale 可能是英文，UI 文案统一中文）
    private static let relativeVerificationFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh-Hans")
        formatter.unitsStyle = .full
        return formatter
    }()

    let vendor: ProviderVendor
    @Binding var draft: VendorDraft

    @EnvironmentObject private var appState: AppState

    @State private var verifyRequestID: UUID?
    @State private var isVerifying = false
    @State private var verifyError: String?
    @State private var showSavedFeedback = false
    /// 最近一次验证通过的凭据指纹；输入改动后按指纹比对自动失效，需重新验证
    @State private var verifiedFingerprint: CredentialFingerprint?
    @State private var isConfirmingRemoval = false
    /// 用户点击"查看"后加载的 Key 明文；nil 表示掩码状态
    @State private var revealedKey: String?
    /// 是否处于"更换 Key"的输入状态
    @State private var isEditingKey = false
    @State private var contextWindowText = ""
    @FocusState private var focusedField: CredentialField?

    private enum CredentialField: Hashable {
        case baseURL
        case apiKey
    }

    /// 验证状态（单一来源，避免散落的条件分支产生矛盾文案）
    private enum VerifyState: Equatable {
        case verifying
        case failed(String)
        case needsVerification
        /// 全新服务商验证通过、模型已就绪，选择模型即完成配置
        case verifiedNewVendor
        case saved
        /// 已保存配置与当前输入一致，可直接切换模型
        case verified
        /// 已保存凭据但从未验证过连接
        case unverifiedSaved
    }

    private var config: ProviderConfig? { appState.config(for: vendor) }

    private var trimmedBaseURL: String {
        draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedAPIKey: String {
        draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 校验门：汇总草稿输入与验证指纹，决定模型列表是否可操作（纯逻辑，可单测）
    private var gate: VendorEditGate {
        VendorEditGate(
            savedBaseURL: config?.baseURL,
            draftBaseURL: draft.baseURL,
            draftAPIKey: draft.apiKey,
            hasLoadedModels: !draft.models.isEmpty,
            verifiedFingerprint: verifiedFingerprint
        )
    }

    /// 模型列表被锁定（需先验证）时显示的橙色提示；nil 表示可直接选择
    private var modelsLockedHint: String? {
        guard !gate.canSelectModel else { return nil }
        return config == nil ? "先验证并加载模型" : "凭据已修改，重新验证后可切换"
    }

    private var verifyState: VerifyState {
        if isVerifying { return .verifying }
        if let verifyError { return .failed(verifyError) }
        if let syncError = appState.providerSyncError, syncError.vendor == vendor {
            return .failed(syncError.message)
        }
        if showSavedFeedback { return .saved }
        if config == nil {
            // 全新服务商：验证通过且模型已就绪，即可选择模型
            return gate.canSelectModel ? .verifiedNewVendor : .needsVerification
        }
        if gate.canSelectModel { return status == .verified ? .verified : .unverifiedSaved }
        return .needsVerification
    }

    private var canVerify: Bool {
        guard !isVerifying else { return false }
        if !vendor.requiresAPIKey { return true }
        return !trimmedBaseURL.isEmpty
            && (!trimmedAPIKey.isEmpty || config?.hasAPIKey == true)
    }

    private var filteredModels: [String] {
        let query = draft.modelSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return draft.models }
        return draft.models.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var status: ConnectionStatus {
        ConnectionStatus(vendor: vendor, config: config)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .opacity(0.65)

            // 页面级滚动：模型列表保底高度可能超出固定窗口（940×600），超出时整页滚动而非压缩列表
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    credentialsCard
                    verifyRow
                    modelSection
                    if vendor.requiresAPIKey {
                        thinkingRow
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .top)
            }

            Divider()
                .opacity(0.65)

            footer
        }
        .onAppear(perform: syncDraftFromConfigIfNeeded)
        .onChange(of: config) { _, _ in syncDraftFromConfigIfNeeded() }
        .task(id: verifyRequestID) {
            guard verifyRequestID != nil else { return }
            isVerifying = true
            verifyError = nil
            defer {
                verifyRequestID = nil
                isVerifying = false
            }

            do {
                let apiKey = trimmedAPIKey.isEmpty
                    ? appState.revealAPIKey(for: vendor)
                    : trimmedAPIKey
                let loadedModels = try await appState.availableModels(
                    vendor: vendor,
                    baseURL: trimmedBaseURL.isEmpty ? nil : trimmedBaseURL,
                    apiKey: apiKey
                )
                guard !Task.isCancelled else { return }
                draft.models = loadedModels
                draft.modelSearch = ""
                if !loadedModels.contains(draft.selectedModel) {
                    draft.selectedModel = ""
                }
                // 记录本次验证通过的凭据指纹；输入改动后自动失效，需重新验证
                verifiedFingerprint = gate.currentFingerprint
            } catch is CancellationError {
                return
            } catch {
                draft.models = []
                draft.selectedModel = ""
                verifiedFingerprint = nil
                verifyError = error.localizedDescription
            }
        }
        .confirmationDialog(
            "移除 \(vendor.title) 的配置？",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("移除配置", role: .destructive) {
                removeConfiguration()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除已保存的 API Key 与模型选择，对话会立即停用该服务商。")
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 13) {
            VendorBrandIcon(vendor: vendor, tileSize: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(vendor.title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Text(vendor.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(status.color)
                    .frame(width: 7, height: 7)
                Text(status.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary, in: Capsule())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: 凭据

    /// 凭据区：API Key 服务商显示 Base URL + Key；
    /// 订阅类（ChatGPT/Codex）显示登录说明（登录态由 codex CLI 管理）。
    @ViewBuilder
    private var credentialsCard: some View {
        if vendor.requiresAPIKey {
            VStack(spacing: 0) {
                SettingInputRow(icon: "network", title: "Base URL") {
                    TextField(
                        vendor.defaultBaseURL.isEmpty ? "https://api.example.com/v1" : vendor.defaultBaseURL,
                        text: $draft.baseURL
                    )
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .baseURL)
                    .accessibilityLabel("Base URL")
                }

                Divider()
                    .padding(.leading, 54)

                SettingInputRow(icon: "key.fill", title: "API Key") {
                    apiKeyRow
                }
            }
            .background(DiscoTheme.surface, in: RoundedRectangle(cornerRadius: DiscoRadius.small))
        } else {
            subscriptionCard
        }
    }

    /// 订阅服务商说明卡：无需 API Key，登录态由 codex CLI 管理（ADR-003）
    private var subscriptionCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DiscoTheme.accent)
                .frame(width: 30, height: 30)
                .background(DiscoTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: DiscoRadius.small))

            VStack(alignment: .leading, spacing: 3) {
                Text(vendor == .opencode ? "使用本机 OpenCode CLI" : "使用 Codex (OpenAI) 登录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(vendor == .opencode
                    ? "无需 API Key：认证与模型由 opencode CLI 管理（opencode auth login）。"
                    : "无需 API Key：登录态由本机 codex CLI 管理（~/.codex）。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(DiscoTheme.surface, in: RoundedRectangle(cornerRadius: DiscoRadius.small))
    }

    /// Key 行三态：已保存（掩码，可查看/更换）、查看明文、输入新 Key
    @ViewBuilder
    private var apiKeyRow: some View {
        if let revealedKey {
            HStack(spacing: 8) {
                Text(revealedKey)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                keyRowButton(icon: "eye.slash", help: "隐藏 Key") {
                    self.revealedKey = nil
                }
                keyRowButton(icon: "pencil", help: "更换 Key") {
                    self.revealedKey = nil
                    isEditingKey = true
                }
            }
        } else if config?.hasAPIKey == true && !isEditingKey {
            HStack(spacing: 8) {
                // 固定长度掩码，不泄露 Key 的真实长度
                Text("••••••••••••••••")
                    .foregroundStyle(.secondary)

                Spacer(minLength: 4)

                keyRowButton(icon: "eye", help: "查看 Key") {
                    revealedKey = appState.revealAPIKey(for: vendor)
                }
                keyRowButton(icon: "pencil", help: "更换 Key") {
                    isEditingKey = true
                }
            }
        } else {
            HStack(spacing: 8) {
                keyInputField

                if !draft.apiKey.isEmpty {
                    keyRowButton(icon: draft.isKeyVisible ? "eye.slash" : "eye",
                                 help: draft.isKeyVisible ? "隐藏 Key" : "显示 Key") {
                        draft.isKeyVisible.toggle()
                    }
                }

                if config?.hasAPIKey == true {
                    Button("取消") {
                        isEditingKey = false
                        draft.apiKey = ""
                        draft.isKeyVisible = false
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func keyRowButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private var keyInputField: some View {
        let placeholder = (config?.hasAPIKey ?? false) ? "输入新的 API Key" : "输入 API Key"
        if draft.isKeyVisible {
            TextField(placeholder, text: $draft.apiKey)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .apiKey)
                .accessibilityLabel("API Key")
        } else {
            SecureField(placeholder, text: $draft.apiKey)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .apiKey)
                .accessibilityLabel("API Key")
        }
    }

    // MARK: 验证（验证通过即具备保存条件，选模型时自动保存）

    private var verifyRow: some View {
        HStack(spacing: 14) {
            verifyStatusLabel

            Spacer(minLength: 12)

            Button {
                verifyRequestID = UUID()
            } label: {
                HStack(spacing: 8) {
                    if isVerifying {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "checkmark.shield")
                    }
                    Text(isVerifying ? "正在验证" : "验证并加载模型")
                }
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(minWidth: 140)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(DiscoTheme.accent, in: Capsule())
            }
            .buttonStyle(DiscoPressButtonStyle())
            .disabled(!canVerify)
            .opacity(canVerify || isVerifying ? 1 : 0.4)
        }
        .frame(minHeight: 34)
    }

    @ViewBuilder
    private var verifyStatusLabel: some View {
        switch verifyState {
        case .verifying:
            StatusLabel(icon: "ellipsis", text: "正在连接服务并读取模型", color: .secondary)
        case let .failed(message):
            StatusLabel(icon: "exclamationmark.circle.fill", text: message, color: .red)
                .help(message)
        case .needsVerification:
            StatusLabel(
                icon: "circle.dotted",
                text: config == nil ? "填写凭据后验证，选模型即完成配置" : "凭据已修改，重新验证后可切换",
                color: .secondary
            )
        case .verifiedNewVendor:
            StatusLabel(icon: "checkmark.circle", text: "验证通过，选择模型完成配置", color: .green)
        case .saved:
            StatusLabel(icon: "checkmark.circle.fill", text: "配置已保存", color: .green)
        case .verified:
            StatusLabel(icon: "checkmark.circle", text: "配置有效，可直接切换模型", color: .secondary)
        case .unverifiedSaved:
            StatusLabel(icon: "exclamationmark.circle", text: "已保存凭据，尚未验证连接", color: .orange)
        }
    }

    // MARK: 模型

    @ViewBuilder
    private var modelSection: some View {
        if draft.models.isEmpty {
            HStack(spacing: 13) {
                Image(systemName: "square.stack.3d.up")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("还没有模型列表")
                        .font(.callout.weight(.medium))
                    Text("验证成功后在这里选择模型，选择即保存")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DiscoTheme.surface, in: RoundedRectangle(cornerRadius: DiscoRadius.small))
        } else {
            VStack(spacing: 0) {
                HStack(alignment: .center) {
                    Text("选择模型")
                        .font(.headline)
                    if let hint = modelsLockedHint {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    if draft.models.count > Self.maxVisibleModelRows {
                        HStack(spacing: 7) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("筛选模型", text: $draft.modelSearch)
                                .textFieldStyle(.plain)
                                .frame(width: 140)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: Capsule())
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)

                if filteredModels.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        Text("没有匹配“\(draft.modelSearch)”的模型")
                            .font(.callout)
                        Spacer()
                    }
                    .padding(16)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredModels, id: \.self) { model in
                                ModelSelectionRow(
                                    model: model,
                                    isSelected: draft.selectedModel == model
                                ) {
                                    selectModel(model)
                                }
                                .disabled(!gate.canSelectModel)
                                .opacity(gate.canSelectModel ? 1 : 0.45)

                                if model != filteredModels.last {
                                    Divider()
                                        .padding(.leading, 46)
                                }
                            }
                        }
                    }
                    // 固定可视高度：避免被凭据等区块挤压成 1~2 行；超过上限的模型在列表内滚动 + 筛选
                    .frame(height: Self.visibleModelListHeight(for: filteredModels.count))
                }
            }
            .background(DiscoTheme.surface, in: RoundedRectangle(cornerRadius: DiscoRadius.small))

            contextWindowEditor
                .onAppear(perform: syncContextWindowText)
                .onChange(of: draft.selectedModel) { _, _ in syncContextWindowText() }
        }
    }

    /// 模型列表可视行数上限：超过后列表内部滚动，并出现筛选框
    private static let maxVisibleModelRows = 8

    /// 列表可视高度：按模型数量自适应（每行最小高 40 + 分隔线 1），模型多时封顶
    private static func visibleModelListHeight(for modelCount: Int) -> CGFloat {
        let rowUnitHeight: CGFloat = 41
        return CGFloat(min(modelCount, maxVisibleModelRows)) * rowUnitHeight
    }

    private var contextWindowEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("上下文窗口")
                    .font(.callout.weight(.medium))
                Spacer()
                Text(contextWindowSource)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                TextField("未知（填写覆盖值）", text: $contextWindowText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveContextWindowOverride)
                Text("tokens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("可填 4,096～16,777,216 的整数；清空后恢复服务商或客户端值。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(DiscoTheme.surface, in: RoundedRectangle(cornerRadius: DiscoRadius.small))
    }

    private var contextWindowSource: String {
        if appState.contextWindowOverride(for: vendor, model: draft.selectedModel) != nil {
            return "用户覆盖"
        }
        if appState.contextWindow(for: vendor, model: draft.selectedModel) != nil {
            return "服务商或客户端"
        }
        return "未知"
    }

    private func syncContextWindowText() {
        let value = appState.contextWindowOverride(for: vendor, model: draft.selectedModel)
        contextWindowText = value.map(String.init) ?? ""
    }

    private func saveContextWindowOverride() {
        let text = contextWindowText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty || (Int(text) != nil) else { return }
        appState.setContextWindowOverride(
            text.isEmpty ? nil : Int(text),
            for: draft.selectedModel,
            vendor: vendor
        )
    }

    // MARK: 选项

    private var thinkingRow: some View {
        let efforts = appState.reasoningEfforts(for: vendor)
        let supportsMultipleEfforts = efforts.count > 2
        let caption: String
        if config == nil {
            caption = "完成配置后可调整"
        } else if supportsMultipleEfforts {
            caption = "选择关闭、低、高或最高"
        } else {
            caption = "开启后该服务商的请求会先进行推理"
        }
        return SettingInputRow(
            icon: "brain",
            title: supportsMultipleEfforts ? "推理强度" : "思考模式",
            caption: caption
        ) {
            if supportsMultipleEfforts {
                Picker(
                    "推理强度",
                    selection: Binding(
                        get: { appState.selectedReasoningEffort(for: vendor) ?? "high" },
                        set: { appState.setReasoningEffort($0, for: vendor) }
                    )
                ) {
                    ForEach(efforts, id: \.self) { effort in
                        Text(ProviderVendor.reasoningEffortTitle(effort))
                            .tag(effort)
                    }
                }
                .pickerStyle(.menu)
                .disabled(config == nil)
                .accessibilityLabel("推理强度")
            } else {
                Toggle(
                    "思考模式",
                    isOn: Binding(
                        get: { config?.thinkingEnabled ?? true },
                        set: { appState.setThinkingEnabled($0, for: vendor) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(config == nil)
                .accessibilityLabel("思考模式")
            }
        }
        .background(DiscoTheme.surface, in: RoundedRectangle(cornerRadius: DiscoRadius.small))
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 12) {
            if config != nil {
                Button("移除配置…", role: .destructive) {
                    isConfirmingRemoval = true
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
            }

            Spacer()

            if let verifiedAt = config?.lastVerifiedAt {
                Text("上次验证 \(Self.relativeVerificationFormatter.localizedString(for: verifiedAt, relativeTo: .now))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: 动作

    /// 选择模型即保存配置（此时凭据已验证通过）
    private func selectModel(_ model: String) {
        draft.selectedModel = model
        do {
            try appState.saveProviderConfig(
                vendor: vendor,
                baseURL: draft.baseURL,
                apiKey: draft.apiKey,
                model: model,
                models: draft.models
            )
            draft.apiKey = ""
            draft.isKeyVisible = false
            isEditingKey = false
            revealedKey = nil
            verifyError = nil
            verifiedFingerprint = nil
            showSavedFeedback = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                showSavedFeedback = false
            }
        } catch {
            verifyError = error.localizedDescription
        }
    }

    private func removeConfiguration() {
        do {
            try appState.deleteProviderAPIKey(vendor: vendor)
            draft = VendorDraft(baseURL: vendor.defaultBaseURL)
            isEditingKey = false
            revealedKey = nil
            verifyError = nil
            verifiedFingerprint = nil
        } catch {
            verifyError = error.localizedDescription
        }
    }

    /// 首次进入或配置外部变化时，用已保存配置填充草稿；用户已输入新 Key 时不覆盖
    private func syncDraftFromConfigIfNeeded() {
        guard draft.apiKey.isEmpty else { return }
        if draft.baseURL.isEmpty {
            draft.baseURL = config?.baseURL ?? vendor.defaultBaseURL
        }
        draft.models = config?.models ?? draft.models
        if let savedModel = config?.model, !savedModel.isEmpty {
            draft.selectedModel = savedModel
        }
    }
}

// MARK: - 辅助控件

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
            .transition(.opacity)
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
                    Text("使用中")
                        .font(.caption)
                        .foregroundStyle(DiscoTheme.accent)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .discoRowStyle(isSelected: isSelected, isHovered: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(model)
        .accessibilityValue(isSelected ? "使用中" : "未选择")
    }
}
