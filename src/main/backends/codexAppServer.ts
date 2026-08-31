import { spawn, type ChildProcess } from "node:child_process";
import { createInterface } from "node:readline";
import type { Readable, Writable } from "node:stream";
import type {
  ModelInfo,
  ReasoningEffort,
  SandboxMode,
} from "../../shared/types.js";
import { findExecutable } from "./executable.js";

export type JsonRpcId = number | string;

export interface AppServerNotification {
  method: string;
  params?: unknown;
}

export interface AppServerRequest extends AppServerNotification {
  id: JsonRpcId;
}

interface AppServerError {
  code: number;
  message: string;
}

interface AppServerResponse {
  id: JsonRpcId;
  result?: unknown;
  error?: AppServerError;
}

interface JsonRpcConnectionHandlers {
  onNotification: (notification: AppServerNotification) => void;
  onRequest: (request: AppServerRequest) => Promise<unknown>;
  onClosed: (error: Error) => void;
  onProtocolError: (error: Error) => void;
  requestTimeoutMs: number;
}

export class JsonRpcConnection {
  private readonly pendingRequests = new Map<
    JsonRpcId,
    {
      resolve: (result: unknown) => void;
      reject: (error: Error) => void;
      timeout: NodeJS.Timeout;
    }
  >();
  private readonly lineReader;
  private nextRequestId = 1;
  private closed = false;
  private closedError: Error | undefined;

  constructor(
    input: Readable,
    private readonly output: Writable,
    private readonly handlers: JsonRpcConnectionHandlers,
  ) {
    this.lineReader = createInterface({
      input,
      crlfDelay: Infinity,
    });
    this.lineReader.on("line", (line: string) => this.handleLine(line));
    input.once("error", (error: Error) => this.close(error));
    input.once("end", () =>
      this.close(new Error("Codex app-server 输出流已关闭")),
    );
  }

  request<TResult>(method: string, params?: unknown): Promise<TResult> {
    if (this.closed) {
      return Promise.reject(
        this.closedError ?? new Error("Codex app-server 连接已关闭"),
      );
    }

    const id = this.nextRequestId;
    this.nextRequestId += 1;
    return new Promise<TResult>((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pendingRequests.delete(id);
        const timeoutError = new Error(
          `Codex app-server 请求超时：${method}`,
        );
        reject(timeoutError);
        this.close(timeoutError);
      }, this.handlers.requestTimeoutMs);
      this.pendingRequests.set(id, {
        resolve: (result) => resolve(result as TResult),
        reject,
        timeout,
      });
      try {
        this.write({ method, id, params });
      } catch (error) {
        const writeError = toError(error);
        reject(writeError);
        this.close(writeError);
      }
    });
  }

  notify(method: string, params: unknown = {}): void {
    if (this.closed) {
      throw this.closedError ?? new Error("Codex app-server 连接已关闭");
    }
    this.write({ method, params });
  }

  close(error = new Error("Codex app-server 连接已关闭")): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    this.closedError = error;
    this.lineReader.close();
    for (const pendingRequest of this.pendingRequests.values()) {
      clearTimeout(pendingRequest.timeout);
      pendingRequest.reject(error);
    }
    this.pendingRequests.clear();
    this.handlers.onClosed(error);
  }

  private write(message: Record<string, unknown>): void {
    this.output.write(`${JSON.stringify(message)}\n`);
  }

  private handleLine(line: string): void {
    const trimmedLine = line.trim();
    if (!trimmedLine) {
      return;
    }

    let parsedMessage: unknown;
    try {
      parsedMessage = JSON.parse(trimmedLine);
    } catch (error) {
      this.handlers.onProtocolError(
        new Error(`无法解析 Codex app-server 消息：${toError(error).message}`),
      );
      return;
    }
    const message = recordValue(parsedMessage);
    if (!message) {
      this.handlers.onProtocolError(
        new Error("Codex app-server 消息必须是 JSON 对象"),
      );
      return;
    }

    const method = stringValue(message.method);
    const id = rpcIdValue(message.id);
    if (method && id !== undefined) {
      void this.handleServerRequest({
        method,
        id,
        params: message.params,
      });
      return;
    }
    if (id !== undefined) {
      this.handleResponse({
        id,
        result: message.result,
        error: appServerErrorValue(message.error),
      });
      return;
    }
    if (method) {
      try {
        this.handlers.onNotification({
          method,
          params: message.params,
        });
      } catch (error) {
        this.handlers.onProtocolError(toError(error));
      }
      return;
    }

    this.handlers.onProtocolError(
      new Error("Codex app-server 消息缺少 method 或 id"),
    );
  }

  private handleResponse(response: AppServerResponse): void {
    const pendingRequest = this.pendingRequests.get(response.id);
    if (!pendingRequest) {
      return;
    }
    this.pendingRequests.delete(response.id);
    clearTimeout(pendingRequest.timeout);
    if (response.error) {
      pendingRequest.reject(
        new Error(
          `Codex app-server 请求失败（${response.error.code}）：${response.error.message}`,
        ),
      );
      return;
    }
    pendingRequest.resolve(response.result);
  }

  private async handleServerRequest(request: AppServerRequest): Promise<void> {
    if (this.closed) {
      return;
    }
    try {
      const result = await this.handlers.onRequest(request);
      if (!this.closed) {
        this.write({ id: request.id, result });
      }
    } catch (error) {
      if (!this.closed) {
        this.write({
          id: request.id,
          error: {
            code: -32000,
            message: toError(error).message,
          },
        });
      }
    }
  }
}

export interface ThreadStartParams {
  cwd: string;
  model?: string;
  approvalPolicy: "never" | "on-request";
  sandbox: SandboxMode;
}

export interface ThreadResumeParams extends ThreadStartParams {
  threadId: string;
}

export interface TurnStartParams {
  threadId: string;
  input: Array<{ type: "text"; text: string }>;
  effort?: ReasoningEffort;
}

export interface TurnInterruptParams {
  threadId: string;
  turnId: string;
}

export interface ThreadResponse {
  thread: { id: string };
}

export interface TurnResponse {
  turn: { id: string };
}

export interface CodexAppServerClient {
  onNotification(
    handler: (notification: AppServerNotification) => void,
  ): () => void;
  onServerRequest(
    handler: (request: AppServerRequest) => Promise<unknown>,
  ): () => void;
  onError(handler: (error: Error) => void): () => void;
  startThread(params: ThreadStartParams): Promise<ThreadResponse>;
  resumeThread(params: ThreadResumeParams): Promise<ThreadResponse>;
  startTurn(params: TurnStartParams): Promise<TurnResponse>;
  interruptTurn(params: TurnInterruptParams): Promise<unknown>;
  shutdown(): Promise<void>;
}

export interface CodexAppServerOptions {
  executablePath?: string;
  clientName?: string;
  clientTitle?: string;
  clientVersion?: string;
  requestTimeoutMs?: number;
  env?: NodeJS.ProcessEnv;
}

export class CodexAppServer implements CodexAppServerClient {
  private readonly notificationHandlers = new Set<
    (notification: AppServerNotification) => void
  >();
  private readonly errorHandlers = new Set<(error: Error) => void>();
  private serverRequestHandler:
    | ((request: AppServerRequest) => Promise<unknown>)
    | undefined;
  private child: ChildProcess | undefined;
  private connection: JsonRpcConnection | undefined;
  private startPromise: Promise<void> | undefined;
  private isStopping = false;

  constructor(private readonly options: CodexAppServerOptions = {}) {}

  onNotification(
    handler: (notification: AppServerNotification) => void,
  ): () => void {
    this.notificationHandlers.add(handler);
    return () => this.notificationHandlers.delete(handler);
  }

  onServerRequest(
    handler: (request: AppServerRequest) => Promise<unknown>,
  ): () => void {
    this.serverRequestHandler = handler;
    return () => {
      if (this.serverRequestHandler === handler) {
        this.serverRequestHandler = undefined;
      }
    };
  }

  onError(handler: (error: Error) => void): () => void {
    this.errorHandlers.add(handler);
    return () => this.errorHandlers.delete(handler);
  }

  async startThread(params: ThreadStartParams): Promise<ThreadResponse> {
    return this.request<ThreadResponse>("thread/start", params);
  }

  async resumeThread(params: ThreadResumeParams): Promise<ThreadResponse> {
    return this.request<ThreadResponse>("thread/resume", params);
  }

  async startTurn(params: TurnStartParams): Promise<TurnResponse> {
    return this.request<TurnResponse>("turn/start", params);
  }

  async listModels(): Promise<ModelInfo[]> {
    const models: ModelInfo[] = [];
    let cursor: string | undefined;
    do {
      const params: { limit: number; includeHidden: boolean; cursor?: string } =
        {
          limit: 100,
          includeHidden: false,
        };
      if (cursor) {
        params.cursor = cursor;
      }
      const result = await this.request<unknown>("model/list", params);
      const resultRecord = recordValue(result);
      const data = Array.isArray(resultRecord?.data)
        ? resultRecord.data
        : [];
      for (const item of data) {
        const model = toModelInfo(item);
        if (model && !models.some((existing) => existing.id === model.id)) {
          models.push(model);
        }
      }
      cursor = stringValue(resultRecord?.nextCursor);
    } while (cursor);
    return models;
  }

  async interruptTurn(params: TurnInterruptParams): Promise<unknown> {
    return this.request("turn/interrupt", params);
  }

  async shutdown(): Promise<void> {
    this.isStopping = true;
    const connection = this.connection;
    const child = this.child;
    connection?.close(new Error("Disco 正在关闭"));
    if (child) {
      await terminateChild(child);
    }
    await this.startPromise?.catch(() => {});

    const lateConnection = this.connection;
    const lateChild = this.child;
    if (lateConnection && lateConnection !== connection) {
      lateConnection.close(new Error("Disco 正在关闭"));
    }
    if (lateChild && lateChild !== child) {
      await terminateChild(lateChild);
    }
    this.connection = undefined;
    this.child = undefined;
    this.isStopping = false;
  }

  private async request<TResult>(
    method: string,
    params: unknown,
  ): Promise<TResult> {
    await this.ensureStarted();
    const connection = this.connection;
    if (!connection) {
      throw new Error("Codex app-server 未连接");
    }
    return connection.request<TResult>(method, params);
  }

  private async ensureStarted(): Promise<void> {
    if (this.connection) {
      return;
    }
    if (!this.startPromise) {
      this.startPromise = this.startServer().finally(() => {
        this.startPromise = undefined;
      });
    }
    await this.startPromise;
  }

  private async startServer(): Promise<void> {
    if (this.isStopping) {
      throw new Error("Codex app-server 正在关闭");
    }
    const executablePath = this.options.executablePath ?? findExecutable("codex");
    if (!executablePath) {
      throw new Error("未找到 Codex CLI，请先安装 Codex");
    }

    const environment: NodeJS.ProcessEnv = {
      ...process.env,
      ...this.options.env,
    };
    environment.CODEX_INTERNAL_ORIGINATOR_OVERRIDE ??= "codex_cli_rs";
    const child = spawn(
      executablePath,
      ["app-server", "--listen", "stdio://"],
      {
        env: environment,
        stdio: ["pipe", "pipe", "pipe"],
      },
    );
    if (!child.stdin || !child.stdout || !child.stderr) {
      child.kill();
      throw new Error("无法建立 Codex app-server stdio 通道");
    }
    if (this.isStopping) {
      await terminateChild(child);
      throw new Error("Codex app-server 正在关闭");
    }

    let stderr = "";
    const appendStderr = (chunk: Buffer | string): void => {
      stderr = `${stderr}${chunk.toString()}`.slice(-16_384);
    };
    child.stderr.on("data", appendStderr);

    let processClosed = false;
    let connection: JsonRpcConnection;
    const closeServer = (error: Error, notify: boolean): void => {
      if (processClosed) {
        return;
      }
      processClosed = true;
      if (this.connection === connection) {
        this.connection = undefined;
        this.child = undefined;
      }
      connection.close(error);
      if (!this.isStopping && child.exitCode === null) {
        child.kill();
      }
      if (notify) {
        this.emitError(error);
      }
    };

    connection = new JsonRpcConnection(child.stdout, child.stdin, {
      onNotification: (notification) => this.emitNotification(notification),
      onRequest: (request) => {
        if (!this.serverRequestHandler) {
          return Promise.reject(
            new Error(`不支持 Codex app-server 请求：${request.method}`),
          );
        }
        return this.serverRequestHandler(request);
      },
      onClosed: (error) => closeServer(error, !this.isStopping),
      onProtocolError: (error) => closeServer(error, !this.isStopping),
      requestTimeoutMs: this.options.requestTimeoutMs ?? 30_000,
    });
    child.stdin.on("error", (error) =>
      closeServer(toError(error), !this.isStopping),
    );
    this.connection = connection;
    this.child = child;

    child.once("error", (error) =>
      closeServer(toError(error), !this.isStopping),
    );
    child.once("exit", (code, signal) => {
      const detail = signal ? `signal ${signal}` : `code ${code ?? 1}`;
      const stderrDetail = stderr.trim() ? `：${stderr.trim()}` : "";
      closeServer(
        new Error(`Codex app-server 已退出（${detail}）${stderrDetail}`),
        !this.isStopping,
      );
    });

    try {
      await connection.request("initialize", {
        clientInfo: {
          name: this.options.clientName ?? "disco",
          title: this.options.clientTitle ?? "Disco",
          version: this.options.clientVersion ?? "0.1.0",
        },
        capabilities: {
          experimentalApi: false,
        },
      });
      connection.notify("initialized", {});
    } catch (error) {
      closeServer(toError(error), false);
      await terminateChild(child);
      throw error;
    }
  }

  private emitNotification(notification: AppServerNotification): void {
    for (const handler of this.notificationHandlers) {
      try {
        handler(notification);
      } catch (error) {
        this.emitError(toError(error));
      }
    }
  }

  private emitError(error: Error): void {
    for (const handler of this.errorHandlers) {
      try {
        handler(error);
      } catch {
        // Error observers must not break the app-server transport.
      }
    }
  }
}

export async function listCodexModels(): Promise<ModelInfo[]> {
  const appServer = new CodexAppServer();
  try {
    return await appServer.listModels();
  } catch {
    return [];
  } finally {
    await appServer.shutdown();
  }
}

async function terminateChild(child: ChildProcess): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null) {
    return;
  }
  const exited = new Promise<void>((resolve) => {
    child.once("exit", () => resolve());
  });
  child.kill("SIGTERM");
  await Promise.race([
    exited,
    new Promise<void>((resolve) => setTimeout(resolve, 1_000)),
  ]);
  if (child.exitCode === null && child.signalCode === null) {
    child.kill("SIGKILL");
    await Promise.race([
      exited,
      new Promise<void>((resolve) => setTimeout(resolve, 1_000)),
    ]);
  }
}

function recordValue(value: unknown): Record<string, unknown> | undefined {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return undefined;
  }
  return value as Record<string, unknown>;
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function rpcIdValue(value: unknown): JsonRpcId | undefined {
  return typeof value === "number" || typeof value === "string"
    ? value
    : undefined;
}

function appServerErrorValue(value: unknown): AppServerError | undefined {
  const error = recordValue(value);
  if (!error) {
    return undefined;
  }
  return {
    code: typeof error.code === "number" ? error.code : -32000,
    message: stringValue(error.message) ?? "Codex app-server 未知错误",
  };
}

function toError(error: unknown): Error {
  return error instanceof Error ? error : new Error(String(error));
}

const reasoningEffortValues: ReasoningEffort[] = [
  "minimal",
  "low",
  "medium",
  "high",
  "xhigh",
  "max",
  "ultra",
  "persistent",
];

function toModelInfo(value: unknown): ModelInfo | undefined {
  const model = recordValue(value);
  if (!model) {
    return undefined;
  }
  const id = stringValue(model?.id);
  if (!id || model?.hidden === true) {
    return undefined;
  }
  const name = stringValue(model.displayName) ?? id;
  const reasoningEfforts = Array.isArray(model.supportedReasoningEfforts)
    ? model.supportedReasoningEfforts.flatMap((item) => {
        const effort = recordValue(item)?.reasoningEffort;
        return typeof effort === "string" && reasoningEffortValues.includes(
          effort as ReasoningEffort,
        )
          ? [effort as ReasoningEffort]
          : [];
      })
    : [];
  return {
    id,
    name,
    ...(reasoningEfforts.length > 0 ? { reasoningEfforts } : {}),
  };
}
