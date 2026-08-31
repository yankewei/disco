# Disco

Disco 是仅面向 macOS 的 Electron + TypeScript coding agent 桌面应用。Electron 主进程是唯一的 agent host：Codex 通过本机 `codex app-server` 接入，认证由本机 `codex login` 管理；Claude Code 使用官方 Agent SDK，OpenCode 使用本机 `opencode serve`。

```bash
npm install
npm run dev
npm test
npm run package
```

`npm run package` 生成不发布更新的 macOS universal 包；发布包请执行 `DISCO_UPDATE_URL=<实际更新地址> npm run package:release`。渲染进程不拥有 Node.js 权限，只能调用 preload 暴露的受限 IPC。应用把项目、会话和消息镜像写入自己的 SQLite 数据库，不读取此前 Swift/Rust 版本的本地数据或凭据。
