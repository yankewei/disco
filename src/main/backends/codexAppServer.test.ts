import { PassThrough } from "node:stream";
import { describe, expect, it, vi } from "vitest";
import {
  JsonRpcConnection,
  type AppServerRequest,
} from "./codexAppServer.js";

function nextMessage(output: PassThrough): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const onData = (chunk: Buffer | string): void => {
      output.off("error", onError);
      resolve(JSON.parse(chunk.toString()) as Record<string, unknown>);
    };
    const onError = (error: Error): void => {
      output.off("data", onData);
      reject(error);
    };
    output.once("data", onData);
    output.once("error", onError);
  });
}

function createConnection(
  input: PassThrough,
  output: PassThrough,
  onRequest: (request: AppServerRequest) => Promise<unknown>,
): JsonRpcConnection {
  return new JsonRpcConnection(input, output, {
    onNotification: vi.fn(),
    onRequest,
    onClosed: vi.fn(),
    onProtocolError: vi.fn(),
    requestTimeoutMs: 100,
  });
}

describe("JsonRpcConnection", () => {
  it("发送请求并匹配 JSON-RPC 响应", async () => {
    const input = new PassThrough();
    const output = new PassThrough();
    const connection = createConnection(input, output, async () => ({}));
    const outgoingMessage = nextMessage(output);

    const responsePromise = connection.request<{ value: string }>(
      "thread/start",
      { cwd: "/tmp/project" },
    );
    const request = await outgoingMessage;
    expect(request).toMatchObject({
      id: 1,
      method: "thread/start",
      params: { cwd: "/tmp/project" },
    });

    input.write(
      `${JSON.stringify({ id: request.id, result: { value: "ok" } })}\n`,
    );
    await expect(responsePromise).resolves.toEqual({ value: "ok" });
    connection.close();
  });

  it("回复 app-server 发起的服务端请求", async () => {
    const input = new PassThrough();
    const output = new PassThrough();
    const connection = createConnection(
      input,
      output,
      async (request) => ({ decision: request.method }),
    );
    const outgoingMessage = nextMessage(output);

    input.write(
      `${JSON.stringify({
        id: 9,
        method: "item/commandExecution/requestApproval",
        params: { command: "pwd" },
      })}\n`,
    );

    await expect(outgoingMessage).resolves.toEqual({
      id: 9,
      result: { decision: "item/commandExecution/requestApproval" },
    });
    connection.close();
  });

  it("忽略空行并报告无效 JSON", async () => {
    const input = new PassThrough();
    const output = new PassThrough();
    const onProtocolError = vi.fn();
    const connection = new JsonRpcConnection(input, output, {
      onNotification: vi.fn(),
      onRequest: async () => ({}),
      onClosed: vi.fn(),
      onProtocolError,
      requestTimeoutMs: 100,
    });

    input.write("\nnot-json\n");
    await vi.waitFor(() => expect(onProtocolError).toHaveBeenCalledOnce());
    expect(onProtocolError).toHaveBeenCalledWith(
      expect.objectContaining({ message: expect.stringContaining("无法解析") }),
    );
    connection.close();
  });

  it("将 RPC 错误传递给 pending request", async () => {
    const input = new PassThrough();
    const output = new PassThrough();
    const connection = createConnection(input, output, async () => ({}));
    const outgoingMessage = nextMessage(output);
    const responsePromise = connection.request("thread/start", {
      cwd: "/tmp/project",
    });
    const request = await outgoingMessage;

    input.write(
      `${JSON.stringify({
        id: request.id,
        error: { code: -32001, message: "请求失败" },
      })}\n`,
    );

    await expect(responsePromise).rejects.toThrow("请求失败");
    connection.close();
  });
});
