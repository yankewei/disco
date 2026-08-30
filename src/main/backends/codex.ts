import { Codex, type ThreadEvent } from "@openai/codex-sdk";
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
      event.type === "item.completed" &&
      event.item.type === "agent_message"
    ) {
      emit({ type: "text", text: event.item.text });
      return;
    }
    if (event.type === "item.completed" && event.item.type === "reasoning") {
      emit({ type: "reasoning", text: event.item.text });
      return;
    }
    if (
      (event.type === "item.started" || event.type === "item.completed") &&
      event.item.type === "command_execution"
    ) {
      emit({
        type: "tool",
        id: event.item.id,
        title: event.item.command,
        state: event.type === "item.started" ? "started" : "completed",
        output: event.item.aggregated_output,
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
}
