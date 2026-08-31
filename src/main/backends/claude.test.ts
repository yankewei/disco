import { describe, expect, it, vi } from "vitest";
import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk";
import type { BackendRunContext } from "./types.js";

const { queryMock } = vi.hoisted(() => ({ queryMock: vi.fn() }));
vi.mock("@anthropic-ai/claude-agent-sdk", () => ({ query: queryMock }));

import { ClaudeBackend } from "./claude.js";

function createQuery(messages: SDKMessage[]): {
  close: () => void;
  [Symbol.asyncIterator]: () => AsyncIterator<SDKMessage>;
} {
  return {
    close: vi.fn(),
    async *[Symbol.asyncIterator]() {
      yield* messages;
    },
  };
}

function streamMessage(event: unknown): SDKMessage {
  return {
    type: "stream_event",
    event,
    parent_tool_use_id: null,
    uuid: "message-uuid",
    session_id: "claude-session",
  } as unknown as SDKMessage;
}

describe("ClaudeBackend", () => {
  it("转发文本、推理和工具调用事件", async () => {
    queryMock.mockReturnValue(
      createQuery([
        streamMessage({
          type: "content_block_delta",
          index: 0,
          delta: { type: "text_delta", text: "完成" },
        }),
        streamMessage({
          type: "content_block_delta",
          index: 1,
          delta: { type: "thinking_delta", thinking: "检查中" },
        }),
        streamMessage({
          type: "content_block_start",
          index: 2,
          content_block: {
            type: "tool_use",
            id: "tool-1",
            name: "Bash",
            input: {},
          },
        }),
        streamMessage({
          type: "content_block_delta",
          index: 2,
          delta: {
            type: "input_json_delta",
            partial_json: '{"command":"pwd"}',
          },
        }),
        streamMessage({ type: "content_block_stop", index: 2 }),
        {
          type: "user",
          message: {
            role: "user",
            content: [
              {
                type: "tool_result",
                tool_use_id: "tool-1",
                content: "项目目录",
              },
            ],
          },
          parent_tool_use_id: null,
          uuid: "user-uuid",
          session_id: "claude-session",
        } as unknown as SDKMessage,
        {
          type: "result",
          subtype: "success",
          is_error: false,
          result: "完成",
          session_id: "claude-session",
        } as unknown as SDKMessage,
      ]),
    );
    const emittedEvents: unknown[] = [];
    const context: BackendRunContext = {
      backendSessionId: "claude-session",
      workingDirectory: "/tmp/project",
      prompt: "检查项目",
      mode: "agent",
      emit: (event) => emittedEvents.push(event),
      signal: new AbortController().signal,
      requestApproval: async () => "approved",
    };

    await expect(new ClaudeBackend().run(context)).resolves.toBe(
      "claude-session",
    );
    expect(emittedEvents).toEqual([
      { type: "text", text: "完成" },
      { type: "reasoning", text: "检查中" },
      {
        type: "tool",
        id: "tool-1",
        title: "Bash",
        state: "started",
        input: {},
      },
      {
        type: "tool",
        id: "tool-1",
        title: "Bash",
        state: "started",
        input: { command: "pwd" },
      },
      {
        type: "tool",
        id: "tool-1",
        title: "Bash",
        state: "completed",
        output: "项目目录",
        error: undefined,
      },
    ]);
  });
});
