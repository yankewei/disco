# Disco ACP Facade

> 状态：ACP 是 daemon 唯一 transport；旧 DAP 已在 Rust 与 Swift 两侧全部删除。

Rust daemon 以 ACP v1 stdio transport 对外服务，复用 `AppState`、`RunCoordinator` 和共享
run service。

## 启动

```bash
cd disco-daemon
cargo run -p disco-daemon -- --stdio
```

ACP 模式的约定：

- daemon 只以 `--stdio` 语义运行（App 通过 `disco-daemon --stdio` 启动子进程）；
- stdin/stdout 使用 ACP JSON-RPC line transport；
- stdout 只允许输出协议 frame；
- tracing 日志写入 stderr。

## 已支持的 ACP 能力

### 标准请求和通知

- `initialize`
- `session/new`
- `session/load`
- `session/list`
- `session/delete`
- `session/close`
- `session/prompt`
- `session/cancel`
- `session/request_permission`（daemon 作为 agent 向 client 发起）

当前只协商 ACP v1。`session/list`、`session/delete`、`session/close` 和
`session/load` 会在 `initialize` 的 `agentCapabilities` 中声明。

### Disco metadata 与扩展

ACP v1 将自定义方法限制为以下划线开头，因此 facade 的实际 wire method 使用
`_disco/...`；去掉 transport 保留的下划线后，产品命名空间仍然是 `disco/*`。

当前支持的 Provider 扩展：

- `_disco/provider/configure`
- `_disco/provider/list`
- `_disco/provider/models`
- `_disco/session/messages`
- `_disco/session/compact`
- `_disco/session/collaboration-modes`：查询当前 Agent 实际提供的协作模式；只有返回 `plan` 时客户端才可展示计划模式。
- `_disco/session/collaboration-mode`：切换当前 session 后续 turn 的协作模式；当前仅 Codex app-server 映射为其原生 collaboration mode。
- `_disco/state/snapshot`：返回 daemon revision、Provider、project 和 session 快照；Swift
  侧以此作为重连后的权威状态入口。
- `_disco/event/replay`：按 session 的 epoch 和 sequence 重放连接短暂中断期间的 session
  update。事件仅保留在 daemon 进程内的有限窗口，完整历史仍从 SQLite 恢复。

`_disco/provider/models` 的 `workspacePath` 使用当前项目的绝对路径。它只用于 daemon 内部
向 OpenCode Server 传递 `directory` 查询参数，不是 OpenCode 的 workspace ID；SwiftUI 不
直接访问 OpenCode Server。

上下文压缩事件使用 ACP extension notification `_disco/session/compaction`。其 `update`
payload 遵循 ACP v1 compaction RFD 的 `sessionUpdate: "compaction_update"` 结构；这是
SDK 尚未提供 typed update 时的兼容承载方式。

扩展参数使用 ACP 的 camelCase 字段名。Provider 配置会复用现有 daemon 配置校验、SQLite
持久化和 runtime 装配逻辑。

`session/new` 可以在 `_meta` 中指定 Provider profile：

```json
{
  "_meta": {
    "disco/providerId": "openai_api"
  }
}
```

未指定时使用 daemon 数据库中排序后的第一个已配置 Provider。Provider 配置通过上述 ACP
extension（Disco App 设置页）写入；该选择规则是过渡行为，后续会由正式的默认 Provider
配置替代。

权限请求使用以下 metadata，帮助 Disco client 保留产品语义：

- `disco/approvalId`
- `disco/approvalScope`：`once` 或 `session`
- `disco/approvalFingerprint`

ACP 的 `AllowAlways` 选项在 Disco 中解释为“本会话允许相同 fingerprint”，不会变成全局
永久授权。

状态变更使用 daemon 进程内的单调 `revision` 标记。每条可重放的 `session/update` 和
`_disco/session/compaction` notification 都会在顶层 `_meta` 携带：

- `disco/eventEpoch`：daemon 启动时生成的 epoch；daemon 重启后改变；
- `disco/eventSequence`：同一 session 内从 1 开始递增的序号。

同一 session 的多个 `session/prompt` 请求进入 daemon FIFO mailbox，前一个 prompt 完成
（包括取消或失败）后才开始下一个；`session/cancel` 和权限响应仍可在运行期间重入处理。

## 运行事件映射

ACP facade 消费 daemon 共享 run service 的 `AgentOutput`，并映射为协议事件：

| AgentOutput | ACP update |
|---|---|
| `TextDelta` | `session/update.agent_message_chunk` |
| `ReasoningDelta` | `session/update.agent_thought_chunk` |
| `ToolStarted` | `session/update.tool_call` |
| `ToolCompleted` | `session/update.tool_call_update` |
| `CompactionUpdate` | `_disco/session/compaction`，payload 为 `compaction_update` |
| `ApprovalWaiting` | `session/request_permission` |
| `Completed` | `session/prompt` 返回 `end_turn` |
| `Cancelled` | `session/prompt` 返回 `cancelled` |
| `Failed` | `session/prompt` 返回 JSON-RPC internal error |

Provider 配置、模型目录、session 删除、本地上下文压缩等产品操作由共享 service
（`provider_service.rs`、`session_service.rs`、`compaction_service.rs`）实现，运行主链路
由共享 `run_service.rs` 承担。

## 尚未包含的内容

- user input：交互式提问流程在 daemon 侧 agent loop 尚未实现（Swift 侧旧的本地实现已随本地 runtime 一并删除）；
- account、默认 Provider 和完整 config schema 等更高层 `disco/*` 扩展尚未完成。

## 验证

Rust workspace 测试：

```bash
cargo test --workspace
```

Swift ↔ Rust 的 ACP transport 测试位于 `discoTests/ACPTransportTests.swift`。它会启动
`disco-daemon --stdio`，验证原始 handshake、`ACPDaemonClient` 的 request/response、Provider
extension，并确认 stderr 日志不会污染 stdout 协议流：

```bash
xcodebuild test \
  -project disco.xcodeproj \
  -scheme disco \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO
```
