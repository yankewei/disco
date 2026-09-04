# Disco

Disco 是仅面向 macOS 14+ 的原生 coding agent 桌面应用，使用 SwiftUI/AppKit 实现，不依赖 Electron、Node、Chromium 或 WebView。

## 当前能力

- Codex：直接管理 `codex app-server --listen stdio://`
- OpenCode：直接管理 `opencode serve`，通过本地 HTTP/SSE 通信
- SQLite：保存项目、会话绑定和界面配置；消息历史由 Provider 管理，并在首次启动时迁移旧 Electron 数据库
- Claude Code：原生 v1 暂不支持，历史数据仍会保留
- Provider 登录态：由各自的 CLI 管理，Disco 不读取或复制凭据

本地数据库保存项目、会话和最近一次 Agent 选择。`projects.project_path` 保存项目目录，`sessions.project_id` 关联项目并保存 Agent、Agent 线程 ID 以及会话配置；最近一次 Agent 选择用于创建新会话。消息历史始终通过 Agent 接口恢复，不在 Disco 的 SQLite 中缓存。删除会话只移除 Disco 中的绑定，不删除 Provider 管理的历史。

## 项目结构

```text
Sources/
├── App/                  应用入口、AppDelegate 和 AppModel（组合根）
├── Presentation/         SwiftUI 页面与组件
│   ├── Workspace/         工作区、会话和消息界面
│   └── Settings/          设置界面
├── Domain/               领域模型、消息序列化和时间线构建
├── Application/          AgentHost 与 Provider 统一运行契约
├── Providers/             外部 Agent 适配器
│   ├── Codex/             Codex app-server 适配
│   └── OpenCode/          OpenCode HTTP/SSE 适配
└── Infrastructure/       环境、SQLite、进程和 JSON-RPC 传输实现
Resources/                Info.plist 与应用图标
Tests/                    原生单元测试
Disco.xcodeproj/          Xcode 工程
project.yml               XcodeGen 工程配置
```

依赖方向保持为：`Presentation → App → Application → Domain`，Application 通过统一契约协调 Provider，并通过 Infrastructure 访问 SQLite、进程和传输层。应用入口负责组装具体实现；界面不直接访问 SQLite、子进程或 Provider 协议。

## 构建与测试

需要安装 Xcode、`xcodebuild` 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)：

```bash
brew install xcodegen
xcodegen generate --spec project.yml --project .
xcodebuild -project Disco.xcodeproj -scheme Disco -configuration Debug -sdk macosx CODE_SIGNING_ALLOWED=NO build
xcodebuild test -project Disco.xcodeproj -scheme Disco -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

也可以直接用 Xcode 打开 `Disco.xcodeproj`。修改 `project.yml` 后重新运行 XcodeGen。

## 数据迁移

原生客户端使用：

```text
~/Library/Application Support/Disco/disco.sqlite
```

首次发现旧 Electron 数据库时，会复制数据库及 WAL/SHM sidecar，再由原生存储层完成 schema 迁移。迁移前请退出旧客户端，避免两个客户端同时写入数据。

发布版本需要 Developer ID、Hardened Runtime 和 notarization。原生 v1 初期不启用 App Sandbox，因为需要直接管理用户已安装的 Provider 可执行文件。
