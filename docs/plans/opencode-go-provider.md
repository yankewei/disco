# OpenCode Go Provider

Status: Proposed

Verified against OpenCode documentation: 2026-08-12

Related decision: [ADR 0001](../adr/0001-separate-codex-and-remote-provider-runtimes.md)

## Outcome

Add OpenCode Go as a first-class Subscription Provider. A user can enter the API key supplied by an OpenCode Go subscription, choose an available Go model, start and continue a real coding-agent conversation, and see tool activity and failures through the same Disco run-event UI used by other Runtimes.

OpenCode Go is not a Codex app-server integration and is not a dedicated Rig Provider. It is an OpenAI-compatible remote Provider executed by the Rig Runtime.

## Official protocol

- Default API base URL: `https://opencode.ai/zen/go/v1`
- Chat Completions endpoint: `POST /chat/completions`
- Authentication: subscription API key sent as bearer authentication
- Transport adapter: Rig 0.41.0 `providers::openai` client with the OpenCode Go base URL

The first release must not assume that every listed model implements every OpenAI extension. Streaming, tool calls, reasoning fields, usage data, and model discovery are capabilities detected or verified independently.

## Scope

### Included

- A dedicated `OpenCode Go` accordion item in Provider settings
- API-key storage in macOS Keychain
- A fixed official endpoint in the normal UI
- Model catalog and model selection scoped to OpenCode Go
- Real multi-turn execution through the Rig Runtime
- Streaming assistant text when the selected model supports it
- Disco tool execution for models that support tool calling
- Durable run events, usage reporting when returned, cancellation, and actionable errors
- Selection of OpenCode Go and one of its models from the chat composer

### Not included in the first release

- Reusing an OpenCode CLI login, browser session, or local OpenCode server
- Sending OpenCode Go requests through the Codex app-server
- Treating the subscription as a generic credential for unrelated endpoints
- Assuming all OpenCode Go models have identical reasoning or tool capabilities
- Exposing the API key in settings files, logs, diagnostics, or run events
- A user-visible endpoint override; proxy support can be added later as an explicit advanced feature

## Configuration model

Persist non-secret configuration in Disco settings:

```text
provider_id: opencode-go
endpoint: https://opencode.ai/zen/go/v1
selected_model: <provider model id>
credential_configured: true | false
```

Persist the API key only in macOS Keychain under a provider-specific service and account. Re-saving an empty key keeps the existing credential. Removing the Provider credential must require an explicit user action and remove the Keychain item separately from ordinary model changes.

## Runtime design

Introduce a remote turn request that is independent of any one SDK:

```text
RemoteTurnRequest
├── provider_id
├── model_id
├── conversation history
├── system instructions
├── reasoning preference, when supported
├── available Disco tools
└── cancellation signal
```

Dispatch rules:

```text
Codex Provider      -> Codex Runtime -> codex app-server
OpenCode Go Provider -> Rig Runtime   -> OpenAI-compatible client
DeepSeek Provider   -> Rig Runtime   -> Rig DeepSeek adapter
Kimi Provider       -> Rig Runtime   -> Rig Moonshot adapter
```

The Rig Runtime is responsible for protocol adaptation and the agent loop. Disco remains responsible for workspace tools, approval policy, persistence, and conversion into `RunEventPayload` events.

## Conversation and tools

- Preserve conversation history per Disco task and Provider selection.
- A follow-up turn uses the same history rather than starting a new one-shot completion.
- Convert Rig assistant output, tool requests, tool results, token usage, and terminal status into existing Disco run events.
- Execute only tools registered by Disco; never accept arbitrary tool implementations from a remote response.
- If a model does not support tools, keep ordinary chat available but present that limitation before it is selected for a coding-agent run.
- Cancellation must stop the active remote request and finish the durable run exactly once.

## Model catalog

The catalog belongs to OpenCode Go, not to a global list. Each entry should contain:

```text
id
display_name
capabilities: streaming | tools | reasoning | usage
availability
```

Prefer an official model-list endpoint when OpenCode documents and supports it. Until then, use a maintained catalog with an optional manual model identifier behind an advanced affordance. Do not silently show stale models as available; catalog-fetch failures should preserve the last verified catalog and label it as stale.

## UI behavior

Settings:

- `OpenCode Go` appears as its own Provider accordion item.
- Collapsed state shows `Connected`, `Not configured`, or a concise connection error.
- Expanded state places subscription guidance, API-key entry, connection verification, and model selection directly beneath the Provider row.
- Do not ask for a custom endpoint in the normal flow.

Chat composer:

- Provider/model selection displays `OpenCode Go` as a Provider with its own models.
- Selecting it changes the active Runtime to Rig only for subsequent turns.
- Changing Provider during an active turn is disabled; changing it between turns does not rewrite previous turns.
- Reasoning controls appear only when the selected model advertises compatible reasoning levels.

## Errors and limits

Map transport failures into stable, user-facing categories:

- Missing or rejected subscription key
- Subscription inactive or usage limit reached
- Model unavailable or removed
- Request rate limited
- Model capability mismatch, especially tool calling
- Provider service unavailable
- Malformed provider response
- User cancellation

Preserve the Provider's request identifier and retry metadata for diagnostics, but never persist credentials or raw authorization headers.

## Delivery sequence

1. Deepen `disco-rig-engine` from checkpoint storage into a Runtime interface with one fake transport test.
2. Add the OpenAI-compatible OpenCode Go client using an injected HTTP transport and Keychain credential loader.
3. Map one non-streaming completion into Disco run events.
4. Add persistent multi-turn history and cancellation.
5. Add streaming output.
6. Add tool calling through `disco-tool-runtime`, including approval and exactly-once completion tests.
7. Add the Provider settings accordion and composer selection only after real execution is available.
8. Add model catalog refresh, stale-catalog behavior, capability badges, and usage-limit errors.

## Acceptance criteria

- A newly entered subscription API key is stored in Keychain and absent from the settings file and logs.
- Connection verification distinguishes an invalid key from service unavailability.
- The selected OpenCode Go model completes a real first turn and a context-dependent follow-up turn.
- Streaming text is incremental and does not duplicate content at completion.
- A supported model can request a Disco workspace tool, receive its result, and continue the same turn.
- A model without tool support cannot be presented as fully capable of coding-agent execution.
- Cancellation produces one terminal cancelled event and leaves the next turn usable.
- Rate-limit and subscription-limit responses show actionable messages without losing conversation history.
- Switching back to Codex routes the next turn through the existing app-server path.
- Provider and model lists remain usable when more Providers and models are added.

## Open questions

- Does OpenCode Go expose a stable authenticated model-list endpoint suitable for third-party clients?
- Which current Go models reliably support streaming, tool calls, reasoning controls, and usage fields?
- Are there subscription terms or request headers beyond bearer authentication that third-party clients must preserve?
- Should a task pin its Provider for its lifetime, or allow Provider changes between turns with explicit history conversion?
