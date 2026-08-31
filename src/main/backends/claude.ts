import { query, type SDKMessage } from "@anthropic-ai/claude-agent-sdk";
import type { AgentBackend, BackendEvent, BackendRunContext } from "./types.js";

interface ClaudeEventState {
  readonly toolNamesById: Map<string, string>;
  readonly toolIdsByBlockIndex: Map<number, string>;
  readonly toolInputsById: Map<string, string>;
  hasStreamedText: boolean;
  hasStreamedReasoning: boolean;
}

interface ClaudeToolBlock {
  id: string;
  name: string;
  input: unknown;
}

export class ClaudeBackend implements AgentBackend {
  readonly supportsPlan = true;

  async run({
    backendSessionId,
    workingDirectory,
    prompt,
    mode,
    emit,
    signal,
    requestApproval,
    onBackendSessionId,
  }: BackendRunContext): Promise<string> {
    const abortController = new AbortController();
    const abortQuery = (): void => abortController.abort();
    signal.addEventListener("abort", abortQuery, { once: true });
    if (signal.aborted) {
      abortController.abort();
    }

    const eventState: ClaudeEventState = {
      toolNamesById: new Map(),
      toolIdsByBlockIndex: new Map(),
      toolInputsById: new Map(),
      hasStreamedText: false,
      hasStreamedReasoning: false,
    };
    let resolvedSessionId = backendSessionId;
    let sessionIdReported = backendSessionId !== undefined;
    let closeResponse: (() => void) | undefined;
    let responseCompleted = false;
    try {
      const response = query({
        prompt,
        options: {
          cwd: workingDirectory,
          resume: backendSessionId,
          abortController,
          includePartialMessages: true,
          permissionMode: mode === "plan" ? "plan" : "default",
          settingSources: ["user", "project"],
          canUseTool: async (toolName, input, options) => {
            const decision = await requestApproval(
              toolName,
              options.title,
              input,
            );
            if (decision === "approved") {
              return { behavior: "allow" as const };
            }
            return { behavior: "deny" as const, message: "用户拒绝" };
          },
        },
      });
      closeResponse = () => response.close();
      for await (const message of response) {
        if (message.session_id && message.session_id !== resolvedSessionId) {
          resolvedSessionId = message.session_id;
          sessionIdReported = true;
          onBackendSessionId?.(message.session_id);
        }
        this.emitMessage(message, emit, eventState);
      }
      if (signal.aborted) {
        throw new Error("运行已取消");
      }
      responseCompleted = true;
    } finally {
      signal.removeEventListener("abort", abortQuery);
      if (!responseCompleted) {
        closeResponse?.();
      }
    }

    if (!resolvedSessionId) {
      throw new Error("Claude Code 未返回会话 ID");
    }
    if (!sessionIdReported) {
      onBackendSessionId?.(resolvedSessionId);
    }
    return resolvedSessionId;
  }

  private emitMessage(
    message: SDKMessage,
    emit: (event: BackendEvent) => void,
    eventState: ClaudeEventState,
  ): void {
    if (message.type === "stream_event") {
      const event = message.event;
      if (event.type === "content_block_start") {
        const toolBlock = getToolBlock(event.content_block);
        if (toolBlock) {
          eventState.toolIdsByBlockIndex.set(event.index, toolBlock.id);
          this.emitToolStarted(emit, eventState, toolBlock);
        }
        return;
      }
      if (event.type === "content_block_delta") {
        if (event.delta.type === "text_delta") {
          eventState.hasStreamedText = true;
          emit({ type: "text", text: event.delta.text });
        } else if (event.delta.type === "thinking_delta") {
          eventState.hasStreamedReasoning = true;
          emit({ type: "reasoning", text: event.delta.thinking });
        } else if (event.delta.type === "input_json_delta") {
          const toolId = eventState.toolIdsByBlockIndex.get(event.index);
          if (toolId) {
            eventState.toolInputsById.set(
              toolId,
              `${eventState.toolInputsById.get(toolId) ?? ""}${event.delta.partial_json}`,
            );
          }
        }
        return;
      }
      if (event.type === "content_block_stop") {
        const toolId = eventState.toolIdsByBlockIndex.get(event.index);
        const rawInput = toolId
          ? eventState.toolInputsById.get(toolId)
          : undefined;
        if (toolId && rawInput) {
          this.emitToolStarted(emit, eventState, {
            id: toolId,
            name: eventState.toolNamesById.get(toolId) ?? "工具调用",
            input: parseJsonValue(rawInput),
          });
        }
      }
      return;
    }

    if (message.type === "assistant") {
      for (const contentBlock of message.message.content) {
        const toolBlock = getToolBlock(contentBlock);
        if (toolBlock) {
          this.emitToolStarted(emit, eventState, toolBlock);
        } else if (
          contentBlock.type === "thinking" &&
          !eventState.hasStreamedReasoning
        ) {
          eventState.hasStreamedReasoning = true;
          emit({ type: "reasoning", text: contentBlock.thinking });
        }
      }
      return;
    }

    if (message.type === "user") {
      const content = message.message.content;
      if (typeof content !== "string") {
        for (const contentBlock of content) {
          if (contentBlock.type === "tool_result") {
            const output = formatToolResult(contentBlock.content);
            this.emitToolResult(
              emit,
              eventState,
              contentBlock.tool_use_id,
              output,
              contentBlock.is_error === true,
            );
          }
        }
      }
      return;
    }

    if (message.type === "result") {
      if (message.subtype !== "success") {
        throw new Error(message.errors.join("\n") || "Claude Code 运行失败");
      }
      if (message.is_error) {
        throw new Error(message.result || "Claude Code 运行失败");
      }
      if (!eventState.hasStreamedText && message.result) {
        eventState.hasStreamedText = true;
        emit({ type: "text", text: message.result });
      }
    }
  }

  private emitToolStarted(
    emit: (event: BackendEvent) => void,
    eventState: ClaudeEventState,
    toolBlock: ClaudeToolBlock,
  ): void {
    const toolName = eventState.toolNamesById.get(toolBlock.id) ?? toolBlock.name;
    eventState.toolNamesById.set(toolBlock.id, toolName);
    emit({
      type: "tool",
      id: toolBlock.id,
      title: toolName,
      state: "started",
      input: toolBlock.input,
    });
  }

  private emitToolResult(
    emit: (event: BackendEvent) => void,
    eventState: ClaudeEventState,
    id: string,
    output: string,
    failed: boolean,
  ): void {
    emit({
      type: "tool",
      id,
      title: eventState.toolNamesById.get(id) ?? "工具调用",
      state: failed ? "failed" : "completed",
      output,
      error: failed ? output : undefined,
    });
  }
}

function getToolBlock(value: unknown): ClaudeToolBlock | undefined {
  if (typeof value !== "object" || value === null) {
    return undefined;
  }
  const record = value as Record<string, unknown>;
  const type = record.type;
  if (
    type !== "tool_use" &&
    type !== "server_tool_use" &&
    type !== "mcp_tool_use"
  ) {
    return undefined;
  }
  if (typeof record.id !== "string" || typeof record.name !== "string") {
    return undefined;
  }
  return { id: record.id, name: record.name, input: record.input };
}

function parseJsonValue(value: string): unknown {
  try {
    return JSON.parse(value) as unknown;
  } catch {
    return value;
  }
}

function formatToolResult(content: unknown): string {
  if (content === undefined) {
    return "";
  }
  if (typeof content === "string") {
    return content;
  }
  if (Array.isArray(content)) {
    return content
      .map((item) => {
        if (
          typeof item === "object" &&
          item !== null &&
          "type" in item &&
          item.type === "text" &&
          "text" in item &&
          typeof item.text === "string"
        ) {
          return item.text;
        }
        return JSON.stringify(item);
      })
      .join("\n");
  }
  return JSON.stringify(content) ?? String(content);
}
