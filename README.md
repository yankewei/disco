# Disco

Disco 是仅面向 macOS 14+ 的原生 coding agent 桌面应用，使用 SwiftUI/AppKit 实现，不依赖 Electron、Node、Chromium 或 WebView。

## 当前能力

- Codex：直接管理 `codex app-server --listen stdio://`
- OpenCode：直接管理 `opencode serve`，通过本地 HTTP/SSE 通信
- SQLite：保留项目、会话和消息数据，并在首次启动时迁移旧 Electron 数据库
- Claude Code：原生 v1 暂不支持，历史数据仍会保留
- Provider 登录态：由各自的 CLI 管理，Disco 不读取或复制凭据

## 项目结构

```text
Sources/                  SwiftUI、AppKit、AgentHost、Provider 和 SQLite 实现
Resources/                Info.plist 与应用图标
Tests/                    原生单元测试
Disco.xcodeproj/          Xcode 工程
project.yml               XcodeGen 工程配置
```

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
