import { spawn, type ChildProcess } from "node:child_process";
import { createServer } from "node:net";
import { delimiter, dirname } from "node:path";
import { findExecutable } from "./executable.js";
import type { AgentBackend, BackendEvent, BackendRunContext } from "./types.js";

interface OpenCodeBackendOptions {
  executablePath?: string;
  fetchImplementation?: typeof fetch;
  spawnProcess?: typeof spawn;
}

interface JsonRecord {
  [key: string]: unknown;
}

interface EventStreamState {
  userMessageIds: Set<string>;
}

export class OpenCodeBackend implements AgentBackend {
  readonly supportsPlan = false;
  private readonly executablePath?: string;
  private readonly fetchImplementation: typeof fetch;
  private readonly spawnProcess: typeof spawn;

  constructor(options: OpenCodeBackendOptions = {}) {
    this.executablePath = options.executablePath;
    this.fetchImplementation =
      options.fetchImplementation ?? globalThis.fetch.bind(globalThis);
    this.spawnProcess = options.spawnProcess ?? spawn;
  }

  async run({
    backendSessionId,
    modelId,
    workingDirectory,
    prompt,
    emit,
    signal,
    requestApproval,
    onBackendSessionId,
  }: BackendRunContext): Promise<string> {
    if (signal.aborted) {
      throw new Error("运行已取消");
    }
    const executablePath =
      this.executablePath ?? findExecutable("opencode");
    if (!executablePath) {
      throw new Error("未找到 opencode 命令，请先安装 OpenCode");
    }

    const port = await findFreePort(signal);
    const baseUrl = `http://127.0.0.1:${port}`;
    const serverProcess = this.spawnProcess(
      executablePath,
      [
        "serve",
        "--hostname",
        "127.0.0.1",
        "--port",
        String(port),
      ],
      {
        cwd: workingDirectory,
        env: {
          ...process.env,
          PATH: [dirname(executablePath), process.env.PATH]
            .filter((value): value is string => Boolean(value))
            .join(delimiter),
        },
        stdio: "ignore",
      },
    );
    let processError: Error | undefined;
    const handleProcessError = (error: Error): void => {
      processError = error;
    };
    serverProcess.on("error", handleProcessError);

    const eventStreamController = new AbortController();
    let sessionId = backendSessionId;
    let sessionIdReported = backendSessionId !== undefined;
    let eventStreamPromise: Promise<void> | undefined;
    const abortRun = (): void => {
      eventStreamController.abort();
      if (sessionId) {
        void this.requestJson<boolean>(
          baseUrl,
          this.directoryPath(`/session/${sessionId}/abort`, workingDirectory),
          { method: "POST" },
        ).catch(() => {});
      }
      serverProcess.kill();
    };
    signal.addEventListener("abort", abortRun, { once: true });

    try {
      await this.waitForServer(
        baseUrl,
        signal,
        serverProcess,
        () => processError,
      );
      if (!sessionId) {
        const createdSession = await this.requestJson<{ id: string }>(
          baseUrl,
          this.directoryPath("/session", workingDirectory),
          {
            method: "POST",
            body: JSON.stringify({ title: "新对话" }),
            signal,
          },
        );
        if (!createdSession?.id) {
          throw new Error("OpenCode 未返回会话 ID");
        }
        sessionId = createdSession.id;
        sessionIdReported = true;
        onBackendSessionId?.(sessionId);
      }

      const eventResponse = await this.openEventStream(
        baseUrl,
        workingDirectory,
        eventStreamController.signal,
      );
      if (!eventResponse.body) {
        throw new Error("OpenCode 未提供事件流");
      }
      const eventStreamState: EventStreamState = {
        userMessageIds: new Set(),
      };
      const streamedPartIds = new Set<string>();
      await this.requestJson<undefined>(
        baseUrl,
        this.directoryPath(
          `/session/${sessionId}/prompt_async`,
          workingDirectory,
        ),
        {
          method: "POST",
          body: JSON.stringify({
            parts: [{ type: "text", text: prompt }],
            ...(modelId ? { model: modelId } : {}),
          }),
          signal,
        },
      );
      eventStreamPromise = this.consumeEvents(
        eventResponse.body,
        baseUrl,
        workingDirectory,
        sessionId,
        emit,
        requestApproval,
        signal,
        eventStreamState,
        streamedPartIds,
      );
      await eventStreamPromise;
      if (signal.aborted) {
        throw new Error("运行已取消");
      }
      if (!sessionIdReported) {
        onBackendSessionId?.(sessionId);
      }
      return sessionId;
    } catch (error) {
      eventStreamController.abort();
      if (eventStreamPromise) {
        await eventStreamPromise.catch(() => {});
      }
      throw error;
    } finally {
      signal.removeEventListener("abort", abortRun);
      eventStreamController.abort();
      if (eventStreamPromise) {
        await eventStreamPromise.catch(() => {});
      }
      await terminateProcess(serverProcess);
    }
  }

  private directoryPath(endpointPath: string, directory: string): string {
    return `${endpointPath}?directory=${encodeURIComponent(directory)}`;
  }

  private async waitForServer(
    baseUrl: string,
    signal: AbortSignal,
    serverProcess: ChildProcess,
    getProcessError: () => Error | undefined,
  ): Promise<void> {
    const deadline = Date.now() + 10_000;
    while (Date.now() < deadline) {
      if (signal.aborted) {
        throw new Error("运行已取消");
      }
      const processError = getProcessError();
      if (processError) {
        throw new Error(`OpenCode 启动失败：${processError.message}`);
      }
      if (serverProcess.exitCode !== null) {
        throw new Error("OpenCode 服务提前退出");
      }
      try {
        const response = await fetchWithTimeout(
          this.fetchImplementation,
          `${baseUrl}/global/health`,
          500,
        );
        if (response.ok) {
          return;
        }
      } catch {
        // The server is still starting or the short health request timed out.
      }
      await delay(100);
    }
    throw new Error("OpenCode 服务启动超时");
  }

  private async openEventStream(
    baseUrl: string,
    workingDirectory: string,
    signal: AbortSignal,
  ): Promise<Response> {
    const response = await this.fetchImplementation(
      this.directoryUrl(`${baseUrl}/event`, workingDirectory),
      {
        headers: { accept: "text/event-stream" },
        signal,
      },
    );
    if (!response.ok) {
      throw new Error(`OpenCode 事件流请求失败：${response.status}`);
    }
    return response;
  }

  private async requestJson<ResponseBody>(
    baseUrl: string,
    endpointPath: string,
    init: RequestInit,
  ): Promise<ResponseBody | undefined> {
    const response = await this.fetchImplementation(
      `${baseUrl}${endpointPath}`,
      {
        ...init,
        headers: { "content-type": "application/json", ...init.headers },
      },
    );
    if (!response.ok) {
      const detail = await response.text().catch(() => "");
      const suffix = detail ? `：${detail.slice(0, 300)}` : "";
      throw new Error(`OpenCode 请求失败：${response.status}${suffix}`);
    }
    if (response.status === 204) {
      return undefined;
    }
    const body = await response.text();
    if (!body) {
      return undefined;
    }
    return JSON.parse(body) as ResponseBody;
  }

  private directoryUrl(baseUrl: string, directory: string): string {
    return `${baseUrl}?directory=${encodeURIComponent(directory)}`;
  }

  private async consumeEvents(
    body: ReadableStream<Uint8Array>,
    baseUrl: string,
    workingDirectory: string,
    sessionId: string,
    emit: (event: BackendEvent) => void,
    requestApproval: BackendRunContext["requestApproval"],
    signal: AbortSignal,
    eventStreamState: EventStreamState,
    streamedPartIds: Set<string>,
  ): Promise<void> {
    const reader = body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    let completed = false;

    try {
      while (!completed) {
        const { value, done } = await reader.read();
        buffer += decoder.decode(value, { stream: !done });
        buffer = buffer.replace(/\r\n/g, "\n");

        let boundaryIndex = buffer.indexOf("\n\n");
        while (boundaryIndex !== -1) {
          const block = buffer.slice(0, boundaryIndex);
          buffer = buffer.slice(boundaryIndex + 2);
          const event = parseServerSentEvent(block);
          if (event) {
            completed = await this.handleServerEvent(
              event,
              baseUrl,
              workingDirectory,
              sessionId,
              emit,
              requestApproval,
              signal,
              eventStreamState,
              streamedPartIds,
            );
          }
          if (completed) {
            break;
          }
          boundaryIndex = buffer.indexOf("\n\n");
        }

        if (done) {
          const finalEvent = parseServerSentEvent(buffer);
          if (finalEvent) {
            completed = await this.handleServerEvent(
              finalEvent,
              baseUrl,
              workingDirectory,
              sessionId,
              emit,
              requestApproval,
              signal,
              eventStreamState,
              streamedPartIds,
            );
          }
          break;
        }
      }
    } finally {
      await reader.cancel().catch(() => {});
    }

    if (!completed && !signal.aborted) {
      throw new Error("OpenCode 事件流意外结束");
    }
  }

  private async handleServerEvent(
    event: JsonRecord,
    baseUrl: string,
    workingDirectory: string,
    sessionId: string,
    emit: (event: BackendEvent) => void,
    requestApproval: BackendRunContext["requestApproval"],
    signal: AbortSignal,
    eventStreamState: EventStreamState,
    streamedPartIds: Set<string>,
  ): Promise<boolean> {
    const nestedPayload = recordValue(event.payload);
    const eventPayload =
      nestedPayload && stringValue(nestedPayload.type) ? nestedPayload : event;
    const eventType = stringValue(eventPayload.type);
    const properties = recordValue(eventPayload.properties);
    if (!eventType || !properties) {
      return false;
    }
    const eventSessionId = stringValue(properties.sessionID);
    if (eventSessionId && eventSessionId !== sessionId) {
      return false;
    }

    switch (eventType) {
      case "message.updated": {
        const messageInfo = recordValue(properties.info);
        const messageId = stringValue(messageInfo?.id);
        if (messageInfo?.role === "assistant") {
          if (messageInfo.error) {
            throw new Error(formatError(messageInfo.error));
          }
        } else if (messageInfo?.role === "user" && messageId) {
          eventStreamState.userMessageIds.add(messageId);
        }
        return false;
      }
      case "message.part.delta":
        this.emitPartDelta(
          properties,
          emit,
          eventStreamState,
          streamedPartIds,
        );
        return false;
      case "message.part.updated":
        this.emitPartUpdate(
          properties,
          emit,
          eventStreamState,
          streamedPartIds,
        );
        return false;
      case "session.next.text.delta":
        this.emitLegacyTextDelta(properties, emit, streamedPartIds);
        return false;
      case "session.next.text.ended":
        this.emitLegacyTextEnded(properties, emit, streamedPartIds);
        return false;
      case "session.next.reasoning.delta":
        this.emitLegacyReasoningDelta(properties, emit, streamedPartIds);
        return false;
      case "session.next.reasoning.ended":
        this.emitLegacyReasoningEnded(properties, emit, streamedPartIds);
        return false;
      case "session.next.tool.called":
        this.emitLegacyToolStarted(properties, emit);
        return false;
      case "session.next.tool.success":
        this.emitLegacyToolFinished(properties, emit, false);
        return false;
      case "session.next.tool.failed":
        this.emitLegacyToolFinished(properties, emit, true);
        return false;
      case "session.next.shell.started":
        emit({
          type: "tool",
          id: stringValue(properties.callID) ?? crypto.randomUUID(),
          title: stringValue(properties.command) ?? "命令执行",
          state: "started",
          input: { command: properties.command },
        });
        return false;
      case "session.next.shell.ended":
        emit({
          type: "tool",
          id: stringValue(properties.callID) ?? crypto.randomUUID(),
          title: "命令执行",
          state: "completed",
          output:
            stringValue(properties.output) ??
            formatUnknownValue(properties.output),
        });
        return false;
      case "permission.asked":
        await this.handlePermissionRequest(
          properties,
          baseUrl,
          workingDirectory,
          sessionId,
          false,
          requestApproval,
          signal,
        );
        return false;
      case "permission.v2.asked":
        await this.handlePermissionRequest(
          properties,
          baseUrl,
          workingDirectory,
          sessionId,
          true,
          requestApproval,
          signal,
        );
        return false;
      case "question.asked":
      case "question.v2.asked":
        throw new Error("OpenCode 请求了交互式问题，当前不支持该操作");
      case "session.error":
        throw new Error(formatError(properties.error));
      case "session.idle":
        return true;
      case "session.status": {
        const status = recordValue(properties.status);
        const statusType =
          stringValue(status?.type) ?? stringValue(properties.status);
        if (statusType !== "idle") {
          return false;
        }
        return true;
      }
      default:
        return false;
    }
  }

  private emitPartDelta(
    properties: JsonRecord,
    emit: (event: BackendEvent) => void,
    eventStreamState: EventStreamState,
    streamedPartIds: Set<string>,
  ): void {
    const partId = stringValue(properties.partID);
    const messageId = stringValue(properties.messageID);
    const delta = stringValue(properties.delta);
    if (
      !partId ||
      delta === undefined ||
      !isAssistantMessagePart(messageId, eventStreamState)
    ) {
      return;
    }
    const field = stringValue(properties.field);
    if (field === "text") {
      streamedPartIds.add(partId);
      emit({ type: "text", text: delta });
    } else if (field === "reasoning") {
      streamedPartIds.add(partId);
      emit({ type: "reasoning", text: delta });
    }
  }

  private emitPartUpdate(
    properties: JsonRecord,
    emit: (event: BackendEvent) => void,
    eventStreamState: EventStreamState,
    streamedPartIds: Set<string>,
  ): void {
    const part = recordValue(properties.part);
    if (!part) {
      return;
    }
    const messageId = stringValue(part.messageID);
    if (!isAssistantMessagePart(messageId, eventStreamState)) {
      return;
    }
    const partId = stringValue(part.id);
    const partType = stringValue(part.type);
    if (!partId || !partType) {
      return;
    }
    const state = messageItemState(part);
    if (partType === "text" && !streamedPartIds.has(partId)) {
      emit({
        type: "item",
        item: {
          id: partId,
          type: "text",
          text: stringValue(part.text) ?? "",
          state,
        },
      });
    } else if (partType === "reasoning" && !streamedPartIds.has(partId)) {
      emit({
        type: "item",
        item: {
          id: partId,
          type: "reasoning",
          text: stringValue(part.text) ?? "",
          state,
        },
      });
    } else if (partType === "tool") {
      this.emitToolPart(part, emit, state);
    } else if (partType === "patch") {
      const files = stringArrayValue(part.files);
      if (files.length > 0) {
        emit({
          type: "item",
          item: {
            id: partId,
            type: "file_change",
            changes: files.map((path) => ({ path, kind: "update" as const })),
            state,
          },
        });
      }
    }
  }

  private emitToolPart(
    part: JsonRecord,
    emit: (event: BackendEvent) => void,
    state: "started" | "updated" | "completed",
  ): void {
    const toolState = recordValue(part.state);
    const status = stringValue(toolState?.status);
    const toolId = stringValue(part.callID) ?? stringValue(part.id);
    if (!toolId) {
      return;
    }
    const title = stringValue(part.tool) ?? "工具调用";
    if (status === "error") {
      const error = stringValue(toolState?.error) ?? "工具调用失败";
      emit({
        type: "tool",
        id: toolId,
        title,
        state: "failed",
        input: toolState?.input,
        output: error,
        error,
      });
    } else if (status === "completed" || state === "completed") {
      emit({
        type: "tool",
        id: toolId,
        title,
        state: "completed",
        input: toolState?.input,
        output:
          stringValue(toolState?.output) ??
          formatUnknownValue(toolState?.output),
      });
    } else {
      emit({
        type: "tool",
        id: toolId,
        title,
        state: "started",
        input: toolState?.input,
      });
    }
  }

  private emitLegacyTextDelta(
    properties: JsonRecord,
    emit: (event: BackendEvent) => void,
    streamedPartIds: Set<string>,
  ): void {
    const partId = stringValue(properties.textID);
    const delta = stringValue(properties.delta);
    if (partId && delta !== undefined) {
      streamedPartIds.add(partId);
      emit({ type: "text", text: delta });
    }
  }

  private emitLegacyTextEnded(
    properties: JsonRecord,
    emit: (event: BackendEvent) => void,
    streamedPartIds: Set<string>,
  ): void {
    const partId = stringValue(properties.textID);
    const text = stringValue(properties.text);
    if (partId && text !== undefined && !streamedPartIds.has(partId)) {
      emit({
        type: "item",
        item: { id: partId, type: "text", text, state: "completed" },
      });
    }
  }

  private emitLegacyReasoningDelta(
    properties: JsonRecord,
    emit: (event: BackendEvent) => void,
    streamedPartIds: Set<string>,
  ): void {
    const partId = stringValue(properties.reasoningID);
    const delta = stringValue(properties.delta);
    if (partId && delta !== undefined) {
      streamedPartIds.add(partId);
      emit({ type: "reasoning", text: delta });
    }
  }

  private emitLegacyReasoningEnded(
    properties: JsonRecord,
    emit: (event: BackendEvent) => void,
    streamedPartIds: Set<string>,
  ): void {
    const partId = stringValue(properties.reasoningID);
    const text = stringValue(properties.text);
    if (partId && text !== undefined && !streamedPartIds.has(partId)) {
      emit({
        type: "item",
        item: { id: partId, type: "reasoning", text, state: "completed" },
      });
    }
  }

  private emitLegacyToolStarted(
    properties: JsonRecord,
    emit: (event: BackendEvent) => void,
  ): void {
    const id = stringValue(properties.callID);
    if (!id) {
      return;
    }
    emit({
      type: "tool",
      id,
      title: stringValue(properties.tool) ?? "工具调用",
      state: "started",
      input: properties.input,
    });
  }

  private emitLegacyToolFinished(
    properties: JsonRecord,
    emit: (event: BackendEvent) => void,
    failed: boolean,
  ): void {
    const id = stringValue(properties.callID);
    if (!id) {
      return;
    }
    const output =
      stringValue(properties.result) ?? formatUnknownValue(properties.result);
    emit({
      type: "tool",
      id,
      title: stringValue(properties.tool) ?? "工具调用",
      state: failed ? "failed" : "completed",
      output,
      error: failed ? output : undefined,
    });
  }

  private async handlePermissionRequest(
    properties: JsonRecord,
    baseUrl: string,
    workingDirectory: string,
    sessionId: string,
    isVersionTwo: boolean,
    requestApproval: BackendRunContext["requestApproval"],
    signal: AbortSignal,
  ): Promise<void> {
    const requestId = stringValue(properties.id);
    const permission =
      stringValue(properties.permission) ?? stringValue(properties.action);
    if (!requestId || !permission) {
      return;
    }
    const metadata = recordValue(properties.metadata);
    const title = stringValue(metadata?.title) ?? permission;
    const decision = await requestApproval(permission, title, {
      permission,
      patterns: properties.patterns ?? properties.resources,
      metadata,
      tool: properties.tool ?? properties.source,
    });
    if (signal.aborted) {
      return;
    }
    const replyPath = isVersionTwo
      ? `/api/session/${sessionId}/permission/${requestId}/reply`
      : `/permission/${requestId}/reply`;
    await this.requestJson<boolean>(
      baseUrl,
      this.directoryPath(replyPath, workingDirectory),
      {
        method: "POST",
        body: JSON.stringify({
          reply: decision === "approved" ? "once" : "reject",
        }),
        signal,
      },
    );
  }
}

function parseServerSentEvent(block: string): JsonRecord | undefined {
  const dataLines = block
    .replace(/\r/g, "")
    .split("\n")
    .filter((line) => line.startsWith("data:"))
    .map((line) => line.slice(5).trimStart());
  if (dataLines.length === 0) {
    return undefined;
  }
  try {
    const parsed: unknown = JSON.parse(dataLines.join("\n"));
    return recordValue(parsed);
  } catch {
    return undefined;
  }
}

function isAssistantMessagePart(
  messageId: string | undefined,
  eventStreamState: EventStreamState,
): boolean {
  return !messageId || !eventStreamState.userMessageIds.has(messageId);
}

function messageItemState(
  part: JsonRecord,
): "started" | "updated" | "completed" {
  const time = recordValue(part.time);
  if (time?.end !== undefined) {
    return "completed";
  }
  return time?.start !== undefined ? "updated" : "started";
}

function recordValue(value: unknown): JsonRecord | undefined {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return undefined;
  }
  return value as JsonRecord;
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function stringArrayValue(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((item): item is string => typeof item === "string")
    : [];
}

function formatUnknownValue(value: unknown): string {
  if (value === undefined) {
    return "";
  }
  if (typeof value === "string") {
    return value;
  }
  return JSON.stringify(value) ?? String(value);
}

function formatError(value: unknown): string {
  const record = recordValue(value);
  if (record?.message && typeof record.message === "string") {
    return record.message;
  }
  const data = recordValue(record?.data);
  if (data?.message && typeof data.message === "string") {
    return data.message;
  }
  return formatUnknownValue(value) || "OpenCode 运行失败";
}

async function findFreePort(signal: AbortSignal): Promise<number> {
  if (signal.aborted) {
    throw new Error("运行已取消");
  }
  const server = createServer();
  return new Promise<number>((resolve, reject) => {
    let settled = false;
    const cleanup = (): void => {
      signal.removeEventListener("abort", handleAbort);
      server.removeListener("error", handleError);
    };
    const rejectOnce = (error: Error): void => {
      if (settled) {
        return;
      }
      settled = true;
      cleanup();
      reject(error);
    };
    const handleAbort = (): void => {
      rejectOnce(new Error("运行已取消"));
      if (server.listening) {
        server.close();
      }
    };
    const handleError = (error: Error): void => {
      rejectOnce(error);
    };
    signal.addEventListener("abort", handleAbort, { once: true });
    server.once("error", handleError);
    server.listen(0, "127.0.0.1", () => {
      if (settled) {
        server.close();
        return;
      }
      const address = server.address();
      server.close((error) => {
        if (error) {
          rejectOnce(error);
        } else if (address && typeof address !== "string") {
          settled = true;
          cleanup();
          resolve(address.port);
        } else {
          rejectOnce(new Error("无法分配 OpenCode 端口"));
        }
      });
    });
  });
}

async function fetchWithTimeout(
  fetchImplementation: typeof fetch,
  url: string,
  timeoutMs: number,
): Promise<Response> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetchImplementation(url, { signal: controller.signal });
  } finally {
    clearTimeout(timeout);
  }
}

async function delay(milliseconds: number): Promise<void> {
  await new Promise<void>((resolve) => setTimeout(resolve, milliseconds));
}

async function terminateProcess(serverProcess: ChildProcess): Promise<void> {
  if (serverProcess.exitCode !== null) {
    return;
  }

  let resolveExit: (() => void) | undefined;
  const exited = new Promise<void>((resolve) => {
    resolveExit = resolve;
  });
  const handleExit = (): void => resolveExit?.();
  serverProcess.once("exit", handleExit);
  serverProcess.kill();
  await Promise.race([exited, delay(1_000)]);
  serverProcess.removeListener("exit", handleExit);
  if (serverProcess.exitCode === null) {
    serverProcess.kill("SIGKILL");
  }
}
