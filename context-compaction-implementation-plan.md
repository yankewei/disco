# Disco 上下文压缩 v1 实现记录

> 状态：已实现主链路，专项测试和少量收尾工作待补充
> 代码基线：`main@531f128`
> 原实施计划：本文件早期版本；当前文档以实际代码为准。

本文记录上下文压缩与用量追踪的当前行为、持久化边界和已知缺口。它不再是待执行的实施计划；如果代码和本文冲突，以代码和测试为准，修改行为时同步更新本文。

## 1. 交付范围

本次实现包含两条独立链路：

- **Generic Runtime**：在 Disco 本地保留完整聊天历史，向模型发送“系统约束 + 历史摘要 + 最近原始消息”；支持自动压缩、手动压缩、checkpoint 持久化，以及 context overflow 后的一次恢复尝试。
- **Codex Runtime**：继续由 Codex app-server 管理线程上下文；Disco 接收真实 token usage、自动压缩生命周期，并通过 `thread/compact/start` 支持手动压缩。

上下文压缩状态展示在现有上下文 popover 中，不进入聊天消息时间线。压缩不会删除、替换或隐藏本地原始消息。

主要实现位置：

| 责任 | 实现 |
| --- | --- |
| 领域契约、usage、checkpoint、压缩状态 | `disco/AgentDomain/ModelContract.swift`、`RuntimeContract.swift` |
| Generic 压缩与 token 粗估 | `disco/AgentRuntime/ContextCompactor.swift`、`TokenEstimator.swift`、`GenericAgentRuntime.swift` |
| Codex usage、自动/手动压缩 | `disco/AgentRuntime/CodexAppServerProtocol.swift`、`CodexAppServerTransport.swift`、`CodexRuntime.swift` |
| Provider usage 与 overflow 分类 | `OpenAIResponsesProvider.swift`、`OpenAIChatCompletionsProvider.swift` |
| checkpoint 持久化与会话状态 | `ConversationPersistence.swift`、`ConversationStore.swift` |
| 设置覆盖值与上下文 UI | `AppState.swift`、`ProviderConfig.swift`、`SettingsView.swift`、`ChatView.swift` |

## 2. Generic Runtime 行为

### 2.1 上下文组装

`ContextCompactor` 使用固定的 `promptVersion = 1` 和 `schemaVersion = 1`。每次请求都会：

1. 注入 `ContextCompactor.runtimeInstructions`，明确当前请求优先于历史内容，历史消息和摘要均是不可信数据。
2. 如果 checkpoint 有效，插入摘要 marker user message 和摘要 assistant message。
3. 追加 checkpoint 边界之后的原始消息。
4. 由 Runtime 追加当前用户输入对应的消息历史。

摘要请求使用当前 Provider 和当前模型，并固定关闭 reasoning、reasoning effort 和 hosted tools。摘要只读取用户/助手可见文本，不保留 reasoning，要求输出以下 Markdown 段落：

- 用户目标
- 约束
- 关键决定
- 已完成工作
- 重要路径与标识符
- 失败与原因
- 待完成事项
- 必须保留事实

摘要目标长度为 `min(2048, max(512, contextWindow × 2%))`；没有已知窗口时使用 1024 的目标值。空摘要或估算长度超过目标两倍时不会创建 checkpoint。

### 2.2 自动压缩

只有模型上下文窗口已知时才按本地阈值自动压缩。策略如下：

```text
outputReserve = min(contextWindow × 25%, max(4096, contextWindow × 15%))
inputBudget   = contextWindow - outputReserve
softTrigger   = min(contextWindow × 72%, inputBudget)
target        = contextWindow × 50%
```

达到 soft trigger 后，压缩最老的完整消息前缀，并至少保留最近 4 个用户轮次。已有 checkpoint 时，摘要会与 checkpoint 边界之后新增的可压缩消息合并。压缩后如果仍超过输入预算，最多再以保留最近 2 个用户轮次的边界折叠一次；仍无法进入预算时返回 overflow，不静默截断最近消息。

窗口未知时不做预防性阈值压缩，只在服务端明确返回 context overflow 后尝试恢复。

### 2.3 手动压缩

- Generic 至少需要 5 个用户轮次，并且存在位于 checkpoint 之后的可压缩完整消息前缀。
- Codex 必须已经有活动 thread，且当前没有正在运行的 turn。
- 压缩期间不能发送消息、重新生成或再次压缩；停止或清空会话会取消压缩任务。
- 手动压缩不创建聊天占位消息。
- 失败时保留上一个有效 checkpoint 和成功记录。

当前 Generic 压缩使用输入预算作为硬约束；`Policy.target` 保留了目标值计算，但并不代表会强制把所有会话压到该数值以下。

### 2.4 Overflow 恢复

Provider 通过 `ModelFailureClassifying` 暴露稳定的 `contextOverflow` 分类。HTTP 400/413 本身不会被当作 overflow；Responses 和 Chat Completions Provider 优先使用服务端的 code/type，必要时才匹配受限的已知错误文本。`finish_reason = length` 仍表示输出长度错误。

主请求满足以下条件时才恢复：

- 尚未向 UI 发出文本、reasoning、hosted tool 或 citation；
- 本轮尚未进行过 overflow recovery。

恢复会生成新的 checkpoint，并重新发送一次主请求。摘要请求本身如果也 overflow，会按候选消息前缀逐步缩小，最多尝试 5 次。再次失败后返回稳定的 `contextOverflow`，提示用户填写上下文窗口、手动压缩或新建会话。

## 3. Checkpoint 与持久化

### 3.1 Checkpoint 内容

`ContextCheckpoint` 是可丢弃的派生缓存，不是聊天事实来源，包含：

- checkpoint ID、schema version、prompt version；
- provider ID 和 model；
- 压缩边界消息 ID；
- 边界之前有序消息 `id + role + text + reasoning` 的 SHA-256 digest；
- 摘要正文和压缩前后 token 估算；
- 创建时间。

加载或发送前必须同时验证 schema、prompt、provider、model、boundary 和 digest。任一项不匹配就丢弃 checkpoint，保留原始消息。

### 3.2 SwiftData 线格式

`PersistedConversation.contextStateData` 保存版本化 JSON：

```swift
struct PersistedConversationContextState {
    let version: Int
    let checkpoint: ContextCheckpoint?
    let lastSuccessfulCompaction: ContextCompactionSnapshot?
}
```

当前版本为 `1`。旧数据库中该字段为 `nil`；JSON 解码失败、版本不支持或校验失败时只丢弃上下文派生状态，不删除会话消息。压缩成功后由 `ConversationStore` 立即持久化，Runtime 不直接访问 SwiftData。

清空会话会同时清除 thread ID、checkpoint、最近压缩记录和 usage；修改 provider 或模型后，旧 checkpoint 因签名不匹配而不会被使用。

## 4. Codex 与 Provider 集成

### 4.1 Provider usage

`ModelEvent.usage(TokenUsageSnapshot)` 不计作文本输出，也不影响运行终止判断：

- Responses Provider 读取 `input_tokens`、`cached_tokens`、`output_tokens`、`reasoning_tokens` 和 `total_tokens`。
- Chat Completions Provider 读取 `prompt_tokens`、`completion_tokens`、`total_tokens` 及可选的 cached/reasoning 明细。
- Chat Completions 的 `include_usage` 尾部 chunk 可以没有 choices，但仍会透传 usage。
- 摘要请求的 usage 不覆盖主请求的上下文占用状态。

### 4.2 Codex app-server

当前 wire 版本对应本机 `codex-cli 0.147.0` 生成的 v2 schema，且对缺少新通知的旧 app-server 做可选解码和降级处理：

- `thread/tokenUsage/updated` → `ContextUsageSnapshot`：`last` 是当前占用，`total` 是累计用量，`modelContextWindow` 是窗口分母。
- `contextCompaction` item started/completed → 自动压缩状态。
- `thread/compact/start` → 手动压缩；等待对应 `contextCompaction` item 完成。
- Codex 不使用 Generic checkpoint，也不在本地按阈值重新总结历史。
- 旧 app-server 如果返回 method-not-found，当前连接会记住手动压缩不可用，但普通对话仍可继续。
- 审批、工具和其他 server request 仍明确返回“不支持”，不能把请求当成已执行。

Codex 的上下文窗口与 usage 来源标记为 `.codex`；Generic 的真实 usage 标记为 `.provider`，本地估算标记为 `.estimate`。

## 5. UI 与配置

Provider 配置支持按模型保存上下文窗口覆盖值：

```text
provider.<vendor>.contextWindowOverrides
```

用户覆盖值优先于模型目录值；合法范围为 4,096～16,777,216 tokens，空值清除覆盖。刷新模型目录不会删除覆盖值，删除 Provider 时一并删除。

上下文 popover 展示：

- 当前占用、上下文窗口、剩余量和占比；
- “服务商返回 / Codex 服务端 / 本地估算”来源；
- 最近一次成功压缩的时间、触发方式、前后 token；
- 正在压缩或失败状态；
- 可用时的“立即压缩”按钮。

### 终止事件不变量

Generic 和 Codex Runtime 都必须保证：一次运行恰好发射一个 `runCompleted`、`runFailed` 或 `runCancelled`，随后结束事件流。usage 和压缩状态事件不能代替终止事件，也不能在终止事件后继续发射。

## 6. 验证状态与后续工作

本次 commit 已覆盖的测试方向主要包括：

- Kimi Chat Completions 请求、thinking、reasoning_content、usage chunk、模型目录和 HTTP 错误；
- Provider/模型上下文窗口目录、legacy metadata 迁移和覆盖值；
- 会话估算 token 数量与上下文状态接入。

以下专项测试仍应补充或加强，完成后再把本文状态改为“已验证”：

- `TokenEstimator` 和 `ContextCompactor` 的边界选择、digest 校验、递归 checkpoint、摘要失败；
- Generic 自动/手动压缩、overflow recovery、可见事件后的禁止重试；
- context state 的 SwiftData 往返、旧库兼容和 checkpoint 失效降级；
- Codex usage/compaction 多 thread 隔离、旧版 method-not-found 和活动 turn 互斥；
- 取消、清空、模型切换时的压缩任务和持久化竞态；
- UI popover 来源、按钮禁用条件和失败提示。

当前仍保留的代码收尾项：`AgentRuntime` 的默认 `compactContext` 扩展是兼容性兜底；Generic 和 Codex 都有真实实现后，可以在确认没有其他 conformer 后删除该兜底和对应 TODO。

## 7. 维护规则

- 修改压缩阈值、摘要 prompt、checkpoint schema 或持久化格式时，先更新本文，再更新代码和测试。
- 修改 Codex CLI 版本时，先重新生成 schema，与现有 DTO/fixture 做 diff；不要只更新版本号。
- 不要把 Generic checkpoint 当成可编辑聊天内容，也不要在 UI 中展示原始摘要为一条聊天消息。
- 不要把 Kimi Code API Provider 描述为 Kimi CLI Agent；两者的工具、审批和 session 能力不同。
