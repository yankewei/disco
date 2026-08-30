import { Codex, type ThreadEvent } from "@openai/codex-sdk";
import type { MessageItem, MessageItemState } from "../../shared/types.js";
import type { AgentBackend, BackendEvent, BackendRunContext } from "./types.js";

export class CodexBackend implements AgentBackend {
  async run({
    backendSessionId,
    workingDirectory,
    prompt,
    emit,
    signal,
  }: BackendRunContext): Promise<string> {
    const codex = new Codex();
    const thread = backendSessionId
      ? codex.resumeThread(backendSessionId, {
          workingDirectory,
          approvalPolicy: "never",
        })
      : codex.startThread({ workingDirectory, approvalPolicy: "never" });
    const streamedTurn = await thread.runStreamed(prompt, { signal });

    for await (const event of streamedTurn.events) {
      this.emitThreadEvent(event, emit);
    }

    return thread.id ?? backendSessionId ?? crypto.randomUUID();
  }

  private emitThreadEvent(
    event: ThreadEvent,
    emit: (event: BackendEvent) => void,
  ): void {
    if (
      event.type === "item.started" ||
      event.type === "item.updated" ||
      event.type === "item.completed"
    ) {
      emit({
        type: "item",
        item: this.toMessageItem(
          event.item,
          event.type === "item.started"
            ? "started"
            : event.type === "item.updated"
              ? "updated"
              : "completed",
        ),
      });
      return;
    }
    if (event.type === "turn.failed") {
      throw new Error(event.error.message);
    }
    if (event.type === "error") {
      throw new Error(event.message);
    }
  }

  private toMessageItem(
    item: Extract<ThreadEvent, { type: "item.started" }>["item"],
    state: MessageItemState,
  ): MessageItem {
    switch (item.type) {
      case "agent_message":
        return { id: item.id, type: "text", text: item.text, state };
      case "reasoning":
        return { id: item.id, type: "reasoning", text: item.text, state };
      case "command_execution":
        return {
          id: item.id,
          type: "command_execution",
          command: item.command,
          output: item.aggregated_output,
          state,
        };
      case "file_change":
        return {
          id: item.id,
          type: "file_change",
          changes: item.changes,
          state,
        };
      case "mcp_tool_call":
        return {
          id: item.id,
          type: "mcp_tool_call",
          server: item.server,
          tool: item.tool,
          arguments: item.arguments,
          result: item.result,
          error: item.error?.message,
          state,
        };
      case "web_search":
        return { id: item.id, type: "web_search", query: item.query, state };
      case "todo_list":
        return { id: item.id, type: "todo_list", items: item.items, state };
      case "error":
        return { id: item.id, type: "error", message: item.message, state };
    }
  }
}
