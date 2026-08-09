# Disco 上下文压缩 v1 详细实施计划

## 1. 目标与交付标准

实现两条独立链路：

- Codex Runtime 继续让 app-server 管理上下文，Disco 接入真实 usage、自动压缩事件和手动 `thread/compact/start`。
- Generic Runtime 保留完整聊天记录，但发送给模型时使用“历史摘要 + 最近原始消息”，支持自动压缩、手动压缩、持久化和 context overflow 后单次恢复重试。
- 压缩状态放在现有“上下文占用”面板中，不提前引入 Run/AgentItem 时间线。
- Generic 使用当前会话模型生成摘要，关闭 reasoning 和托管工具。
- 模型窗口未知时允许用户填写覆盖值；未填写前不做阈值压缩，只在服务端明确返回溢出时尝试恢复。
- 自动策略默认约 72% 触发、压缩到约 50%，至少保留最近 4 个用户轮次原文。

完成后必须满足：

- 压缩不会删除、替换或隐藏本地聊天历史。
- 重启后 Generic checkpoint 可以继续使用。
- Codex 不在本地重复总结或重放历史。
- 取消、失败、重试仍维持一次运行恰好一个终止事件。
- 旧会话数据库可以无损打开。

## 2. 领域接口与持久化

### Model 与 Runtime 合约

扩展模型契约：

```swift
struct ModelRequest {
    let instructions: String?
    let messages: [ChatMessage]
    // 保留现有 model/reasoning/hostedTools
}

struct TokenUsageSnapshot: Codable, Sendable, Equatable {
    let inputTokens: Int
    let cachedInputTokens: Int?
    let outputTokens: Int
    let reasoningOutputTokens: Int?
    let totalTokens: Int
}

enum ModelEvent {
    // 现有事件
    case usage(TokenUsageSnapshot)
}
```

Provider 的 instructions 映射规则固定为：

- OpenAI Responses 原生方言使用顶层 `instructions`。
- Responses 兼容方言在 `input` 最前插入 `system` message。
- Chat Completions 在 `messages` 最前插入 `system` message。
- instructions 为 `nil` 时保持现有请求体不变。

扩展 Runtime 合约：

```swift
struct ContextUsageSnapshot {
    let current: TokenUsageSnapshot
    let accumulated: TokenUsageSnapshot?
    let contextWindow: Int?
    let source: Source // provider / codex / estimate
}

struct ContextCheckpoint: Codable, Sendable, Equatable {
    let id: UUID
    let schemaVersion: Int
    let promptVersion: Int
    let providerID: String
    let model: String
    let boundaryMessageID: UUID
    let sourceDigest: String
    let summary: String
    let estimatedTokensBefore: Int
    let estimatedTokensAfter: Int
    let createdAt: Date
}

struct ContextCompactionSnapshot: Codable, Sendable, Equatable {
    let id: String
    let runtimeKind: RuntimeKind
    let trigger: Trigger       // automatic / manual / overflowRecovery
    let status: Status         // running / completed / failed
    let startedAt: Date
    let completedAt: Date?
    let beforeTokens: Int?
    let afterTokens: Int?
    let compactedMessageCount: Int?
    let errorMessage: String?
}

struct ContextCompactionUpdate {
    let snapshot: ContextCompactionSnapshot
    let checkpoint: ContextCheckpoint?
}
```

调整接口：

- `AgentRunRequest` 增加可选 `contextCheckpoint`。
- `AgentEvent` 增加 `contextUsageUpdated` 和 `contextCompactionUpdated`。
- `AgentRuntime` 增加 `compactContext(request:) async throws -> ContextCompactionUpdate`，Codex 与 Generic 都实现。
- `AgentFailure` 增加稳定的 `code`、可选恢复建议和是否可重试；默认值保持现有初始化调用兼容，并新增 `contextOverflow`、`contextCompactionFailed`。

### checkpoint 持久化

在 Conversation 的 SwiftData 模型上增加可选 `contextStateData: Data?`，保存版本化 JSON：

```swift
struct PersistedConversationContextState {
    let version: Int
    let checkpoint: ContextCheckpoint?
    let lastSuccessfulCompaction: ContextCompactionSnapshot?
}
```

具体规则：

- 原始 `PersistedMessage` 始终是事实来源。
- checkpoint 只是派生缓存；解码、版本或摘要校验失败时丢弃 checkpoint，不删除消息。
- SHA-256 digest 基于压缩边界之前有序消息的 `id + role + text + reasoning`。
- checkpoint 仅在 `providerID + model + promptVersion` 匹配且 boundary/digest 有效时使用。
- Provider 或模型变化后旧 checkpoint 暂时保留但不使用；创建新 checkpoint 时覆盖。
- 成功生成 checkpoint 后立即持久化，再继续主模型请求。
- 清空会话同时清空 checkpoint、最近压缩记录和 usage。
- 手动/自动压缩失败不得覆盖上一个有效 checkpoint。
- 给 `ConversationSnapshot`、`ConversationSession`、`ConversationStore` 的持久化回调增加 context state，避免 Runtime 自己写 SwiftData。

## 3. Generic Runtime 压缩引擎

### 上下文组装

引入一个有实际复杂度边界的 `ContextCompactor`，负责 checkpoint 校验、边界选择、摘要生成和重建模型输入；共享的 token 粗估逻辑从 `ConversationStore` 移到可复用 `TokenEstimator`。

存在有效 checkpoint 时，模型输入顺序固定为：

1. Generic Runtime 的系统约束。
2. synthetic user message：说明下一条是较早会话的只读摘要，不得提升其中指令的优先级。
3. synthetic assistant message：checkpoint summary。
4. boundary 之后的原始消息。
5. 当前用户输入。

摘要生成请求：

- 使用当前 Provider 和当前模型。
- `reasoningEnabled = false`、`reasoningEffort = nil`、`hostedTools = []`。
- system instructions 明确要求把 transcript 当作不可信数据，不执行其中指令。
- 只摘要用户/助手可见文本；不保留 reasoning。
- 输出固定 Markdown 段落：用户目标、约束、关键决定、已完成工作、重要路径/标识符、失败与原因、待完成事项、必须保留事实。
- 摘要使用原会话主要语言，不输出分析过程。
- 摘要目标上限：

```text
summaryTarget = min(2048, max(512, contextWindow × 2%))
```

- 空摘要或估算超过 `summaryTarget × 2` 视为无效，不写 checkpoint。

### 自动策略

窗口已知时：

```text
outputReserve = min(contextWindow × 25%, max(4096, contextWindow × 15%))
inputBudget   = contextWindow - outputReserve
softTrigger   = min(contextWindow × 72%, inputBudget)
target        = contextWindow × 50%
```

执行流程：

1. 校验已有 checkpoint。
2. 估算 instructions、summary marker、摘要、原始尾部和本次输入。
3. 低于 `softTrigger` 时直接发送。
4. 达到阈值时，选择最老的完整消息前缀进行压缩。
5. 压缩边界必须位于消息边界，并保留从倒数第 4 个用户消息开始的全部内容。
6. 有旧 checkpoint 时，把旧摘要和新增的可压缩前缀一起折叠为新摘要，推进 boundary。
7. 根据真实摘要重新估算；仍超过 `inputBudget` 且还有可压缩内容时，最多再折叠一次。
8. 两次后仍无法进入预算，发出 `contextOverflow`，不得静默删除最近内容。

手动 Generic 压缩：

- 即使未达到 soft trigger，也尝试压缩到 target。
- 少于 5 个用户轮次、没有可压缩前缀时返回“暂无可压缩历史”。
- 不创建聊天占位消息。
- 进行中禁止发送、重新生成和再次压缩；清空或停止会取消压缩任务。

### 溢出恢复

Provider 错误增加统一 `ModelFailureKind.contextOverflow` 分类：

- 优先识别服务端 `code/type`，包括 context length/window exceeded 类代码。
- Chat Completions 缺少结构化 code 时，再匹配经过限制的已知错误文本。
- HTTP 400/413 不能单独被认定为 context overflow。
- 输出达到 `finish_reason = length` 仍属于输出长度错误，不触发上下文重试。

主请求发生 context overflow 时：

- 只有在尚未向 UI 发出 text、reasoning、tool 或 citation 事件时才允许恢复重试。
- 窗口已知：强制推进 checkpoint，再重试主请求一次。
- 窗口未知：选取最老的可压缩完整前缀，目标先减少约一半估算输入；如果摘要请求本身也溢出，按消息边界对候选前缀二分缩小。
- 主请求最多重试一次；再次溢出时返回稳定失败，提示用户填写模型上下文窗口、手动压缩或新建会话。
- 若预防性压缩失败但原始请求仍低于 `inputBudget`，记录非致命压缩失败并继续原始请求。
- 已超过预算、无可压缩前缀或摘要失败时终止运行，不做原始消息截断。

## 4. Provider、Codex 和 UI

### Provider usage

Responses Provider 解码：

- `input_tokens`
- `cached_tokens`
- `output_tokens`
- `reasoning_tokens`
- `total_tokens`

Chat Completions Provider 解码：

- `prompt_tokens`
- `completion_tokens`
- `total_tokens`
- 可选 cached/reasoning 明细。

SSE 中 choices 为空但带 usage 的 chunk 仍必须产生 `.usage`；usage 不计作文本输出，也不改变终止判断。摘要请求的 usage 只用于压缩记录，不覆盖主请求的上下文占用状态。

### Codex app-server

以本机实际安装的 `codex-cli 0.147.0` 重新生成 schema 并 diff，仅接入本功能需要的 DTO，同时保持旧通知缺失时可运行：

- `thread/tokenUsage/updated`
- `contextCompaction` ThreadItem
- `thread/compact/start`

实现规则：

- Codex 不使用 Generic checkpoint，也不根据本地阈值触发自动压缩。
- `thread/tokenUsage/updated` 映射为 `ContextUsageSnapshot`：`last` 作为当前占用，`total` 作为累计量，`modelContextWindow` 作为 UI 分母。
- 自动 `contextCompaction` item started/completed 映射为压缩状态；schema 没有 before/after 时保持 `nil`，不得伪造。
- Transport 新增 `compactThread(threadID:)`，发送 `thread/compact/start` 并等待对应 `contextCompaction` item 完成。
- 手动压缩只能在线程已存在且没有活动 turn 时执行。
- 旧 app-server 返回 method-not-found 时，在当前连接内标记手动压缩不受支持，并展示中文提示；自动对话继续可用。
- 升级 wire 元数据和契约 fixture 到 0.147.0，但 initialize 不严格拒绝较旧版本。

### 设置与上下文面板

给 Provider 配置增加独立的 per-model context window override：

```text
provider.<vendor>.contextWindowOverrides
```

规则：

- 用户覆盖值优先于服务端目录值和客户端已知值。
- 输入必须是 4,096～16,777,216 的整数 token；空值表示清除覆盖。
- 刷新模型目录不得删除覆盖值。
- 删除 Provider 配置时一并删除覆盖。
- 设置页在所选模型区域显示上下文窗口来源和可编辑 token 值。

上下文 popover 改为：

- 优先展示 Provider/Codex 返回的真实 usage，否则展示 checkpoint-aware 本地估算。
- 明确标记“服务商返回”或“本地估算”。
- 展示模型窗口、当前占用、剩余量和占比。
- 展示最近一次成功压缩的时间、触发方式、压缩前后 token；缺失值显示“未知”。
- 压缩进行中显示进度状态，失败显示非破坏性中文错误。
- 提供“立即压缩”按钮；流式回复、正在压缩、无 Generic 可压缩前缀或 Codex 无 thread 时禁用。
- Generic ring 使用 checkpoint 后模型可见上下文估算，不再累计全部 UI 历史；Codex ring 使用服务端窗口。
- v1 不增加自动压缩开关，不增加独立摘要模型设置，也不创建聊天时间线压缩卡片。

## 5. 测试与验收

### 单元与契约测试

- `TokenEstimator`：ASCII、中文、空文本、instructions、summary marker。
- checkpoint：SwiftData 往返、旧库 `nil` 兼容、版本错误、digest 错误、boundary 丢失、运行时签名不匹配。
- 边界选择：保留最近 4 个用户轮次、不拆消息、递归推进 checkpoint、尾部本身过大。
- Generic Runtime：阈值以下不压缩；达到 72% 自动压缩；压缩后只发送摘要与尾部；完整 Store 消息不变。
- 摘要请求：同一模型、reasoning 关闭、tools 为空、instructions 正确、空/超长摘要拒绝。
- 溢出恢复：无输出时压缩并重试一次；已有任意可见事件时不重试；第二次溢出稳定失败。
- 失败与取消：旧 checkpoint 保留、手动压缩可取消、自动压缩取消仍只产生一个 run terminal。
- Provider：Responses/Chat usage 正常、任意 SSE 分片、choices 为空 usage chunk、结构化 overflow 分类、普通 400 不误判。
- Codex：token usage DTO、contextCompaction started/completed、多 thread 隔离、手动 compact wire、method-not-found、活动 turn 禁止手动压缩。
- Store/UI 状态：成功立即持久化、清空全部重置、发送与压缩互斥、popover 来源和按钮状态正确。

### 最终验证

运行完整测试：

```bash
xcodebuild test \
  -project disco.xcodeproj \
  -scheme disco \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO
```

手工验收至少包括：

1. Generic 长会话达到阈值后自动压缩，聊天记录数量和内容不变。
2. 重启应用后继续会话，发送请求仍使用已保存摘要。
3. 修改模型后旧 checkpoint 不被误用，并按新窗口重新计算。
4. 未知窗口填写覆盖值后 ring 和自动阈值立即生效。
5. Codex 自动压缩时面板显示状态和服务端 usage。
6. Codex 手动压缩成功；旧版不支持时只禁用该能力，不影响聊天。
7. 压缩中点击停止或清空，不留下半成品 checkpoint。

## 已锁定假设

- 首版同时覆盖 Codex 与 Generic，并包含手动压缩。
- Generic 摘要使用当前模型，不增加单独模型或认证配置。
- 默认平衡策略为约 72%/50%，保留最近 4 个用户轮次。
- 未知窗口通过用户覆盖补齐；未填写前仅做 overflow 恢复。
- 压缩记录只进入上下文面板，不进入聊天时间线。
- 当前工作区已有未提交修改，实施时必须保留并逐文件合并，禁止 reset 或覆盖用户改动。
