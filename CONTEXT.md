# Disco

Disco is a desktop coding-agent client that presents several model sources through one conversation experience while preserving the execution semantics of each source.

## Language

**Provider**:
A named source of models and credentials available to a conversation. A Provider does not imply a particular execution implementation.
_Avoid_: Service, vendor

**Provider Configuration**:
The non-secret connection information and credential reference required to make a Provider available.
_Avoid_: Account, profile

**Subscription Provider**:
A Provider whose API access is granted by a product subscription rather than usage-billed credentials. OpenCode Go is a Subscription Provider.
_Avoid_: Subscription model, bundled model

**Runtime**:
The agent execution boundary that turns conversation input into model requests, tool activity, and durable run events. Codex Runtime and Rig Runtime are distinct Runtimes.
_Avoid_: Provider, backend

**Codex Runtime**:
The Runtime backed by the locally installed Codex app-server and its native thread, tool, approval, and file-change semantics.

**Rig Runtime**:
The Runtime used for remote API Providers that supplies portable model communication and agent execution while Disco owns tools and durable run events.

**OpenCode Go Provider**:
The Subscription Provider that uses an OpenCode Go API key and its OpenAI-compatible model endpoint. It executes through the Rig Runtime, not through the Codex Runtime.

**Model Catalog**:
The models currently selectable for one Provider, including their identifiers and supported capabilities.
_Avoid_: Global model list
