# Disco

Disco 是仅面向 macOS 的 Electron + TypeScript coding agent 桌面应用。Electron 主进程是唯一的 agent host：Codex 使用官方 Codex SDK 和本机 `codex login` 登录态，Claude Code 使用官方 Agent SDK，OpenCode 使用本机 `opencode serve`。

```bash
npm install
npm run dev
npm test
npm run package
```

渲染进程不拥有 Node.js 权限，只能调用 preload 暴露的受限 IPC。应用把项目、会话和消息镜像写入自己的 SQLite 数据库，不读取此前 Swift/Rust 版本的本地数据或凭据。
