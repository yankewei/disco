import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedSection: SettingsSection? = .providers

    private enum SettingsSection: String, CaseIterable, Identifiable {
        case providers
        case general

        var id: Self {
            self
        }

        var title: String {
            switch self {
            case .providers:
                "Provider"
            case .general:
                "通用"
            }
        }

        var systemImage: String {
            switch self {
            case .providers:
                "server.rack"
            case .general:
                "gearshape"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationTitle("设置")
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 210)
        } detail: {
            switch selectedSection ?? .providers {
            case .providers:
                ProviderSettingsView()
            case .general:
                GeneralSettingsView()
            }
        }
        .task {
            await model.refresh()
        }
    }
}

private struct ProviderSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                if model.providers.isEmpty {
                    Text("正在检测 Provider…")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.providers) { provider in
                        ProviderSettingsRow(provider: provider)
                    }
                }
            } header: {
                Text("已安装的 Provider")
            } footer: {
                Text("登录态由各自的 CLI 管理，Disco 不会读取或复制凭据。")
            }

            Section {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("刷新 Provider", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoading)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Provider")
    }
}

private struct ProviderSettingsRow: View {
    let provider: ProviderInfo
    @State private var isShowingModels = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: provider.kind == .codex ? "sparkles" : "terminal")
                    .frame(width: 22)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.kind.displayName)
                    Text(provider.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(
                    provider.available ? "可用" : "不可用",
                    systemImage: provider.available ? "checkmark.circle.fill" : "xmark.circle"
                )
                .font(.caption)
                .foregroundStyle(provider.available ? .green : .secondary)
            }

            if provider.available, !provider.models.isEmpty {
                DisclosureGroup("模型（\(provider.models.count)）", isExpanded: $isShowingModels) {
                    ForEach(provider.models) { model in
                        HStack {
                            Text(model.name)
                            Spacer()
                            Text(model.id)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("数据") {
                LabeledContent("数据库") {
                    Text(model.databaseURL?.path ?? "不可用")
                        .font(.caption)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section("应用") {
                LabeledContent("版本", value: "原生 v1")
                LabeledContent("系统要求", value: "macOS 14 或更高")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("通用")
    }
}
