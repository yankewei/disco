import Database from "better-sqlite3";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import type {
  ProjectInfo,
  RunStatus,
  SessionInfo,
  StoredMessage,
  ToolCall,
} from "../shared/types.js";

interface StoredMessageRow {
  id: string;
  role: "user" | "assistant";
  text: string;
  reasoning: string | null;
  toolsJson: string | null;
  itemsJson: string | null;
  status: RunStatus | null;
  error: string | null;
  createdAt: string;
}

export class DiscoStore {
  private readonly database: Database.Database;
  private isClosed = false;

  constructor(databasePath: string) {
    mkdirSync(dirname(databasePath), { recursive: true });
    this.database = new Database(databasePath);
    this.database.pragma("journal_mode = WAL");
    this.database.exec(`
      CREATE TABLE IF NOT EXISTS projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        path TEXT NOT NULL UNIQUE,
        created_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        backend TEXT NOT NULL,
        backend_session_id TEXT,
        title TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS messages (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        role TEXT NOT NULL,
        text TEXT NOT NULL,
        reasoning TEXT,
        tools_json TEXT,
        items_json TEXT,
        status TEXT,
        error TEXT,
        created_at TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS sessions_project_updated_idx
        ON sessions (project_id, updated_at DESC);
      CREATE INDEX IF NOT EXISTS messages_session_created_idx
        ON messages (session_id, created_at);
    `);

    const messageColumns = this.database
      .prepare("PRAGMA table_info(messages)")
      .all() as Array<{ name: string }>;
    if (!messageColumns.some((column) => column.name === "items_json")) {
      this.database.exec("ALTER TABLE messages ADD COLUMN items_json TEXT");
    }
    if (!messageColumns.some((column) => column.name === "status")) {
      this.database.exec("ALTER TABLE messages ADD COLUMN status TEXT");
    }
    if (!messageColumns.some((column) => column.name === "error")) {
      this.database.exec("ALTER TABLE messages ADD COLUMN error TEXT");
    }
  }

  listProjects(): ProjectInfo[] {
    return this.database
      .prepare(
        "SELECT id, name, path, created_at AS createdAt FROM projects ORDER BY created_at DESC",
      )
      .all() as ProjectInfo[];
  }

  createProject(project: ProjectInfo): void {
    this.database
      .prepare(
        "INSERT INTO projects (id, name, path, created_at) VALUES (@id, @name, @path, @createdAt)",
      )
      .run(project);
  }

  listSessions(projectId: string): SessionInfo[] {
    return this.database
      .prepare(
        `SELECT
          id AS sessionId,
          project_id AS projectId,
          backend,
          backend_session_id AS backendSessionId,
          title,
          updated_at AS updatedAt
        FROM sessions
        WHERE project_id = ?
        ORDER BY updated_at DESC, rowid DESC`,
      )
      .all(projectId) as SessionInfo[];
  }

  getSession(sessionId: string): SessionInfo | undefined {
    return this.database
      .prepare(
        `SELECT
          id AS sessionId,
          project_id AS projectId,
          backend,
          backend_session_id AS backendSessionId,
          title,
          updated_at AS updatedAt
        FROM sessions
        WHERE id = ?`,
      )
      .get(sessionId) as SessionInfo | undefined;
  }

  createSession(session: SessionInfo): void {
    this.database
      .prepare(
        `INSERT INTO sessions (
          id, project_id, backend, backend_session_id, title, updated_at
        ) VALUES (
          @sessionId, @projectId, @backend, @backendSessionId, @title, @updatedAt
        )`,
      )
      .run({
        ...session,
        backendSessionId: session.backendSessionId ?? null,
      });
  }

  updateSession(sessionId: string, backendSessionId: string): void {
    this.database
      .prepare(
        "UPDATE sessions SET backend_session_id = ?, updated_at = ? WHERE id = ?",
      )
      .run(backendSessionId, new Date().toISOString(), sessionId);
  }

  updateSessionTitle(sessionId: string, title: string): void {
    this.database
      .prepare("UPDATE sessions SET title = ? WHERE id = ?")
      .run(title, sessionId);
  }

  appendMessage(sessionId: string, message: StoredMessage): void {
    const insertMessage = this.database.prepare(
      `INSERT INTO messages (
        id,
        session_id,
        role,
        text,
        reasoning,
        tools_json,
        items_json,
        status,
        error,
        created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    );
    const updateSession = this.database.prepare(
      "UPDATE sessions SET updated_at = ? WHERE id = ?",
    );
    const append = this.database.transaction(() => {
      insertMessage.run(
        message.id,
        sessionId,
        message.role,
        message.text,
        message.reasoning ?? null,
        message.toolCalls ? JSON.stringify(message.toolCalls) : null,
        message.items ? JSON.stringify(message.items) : null,
        message.status ?? null,
        message.error ?? null,
        message.createdAt,
      );
      updateSession.run(message.createdAt, sessionId);
    });
    append();
  }

  messages(sessionId: string): StoredMessage[] {
    const rows = this.database
      .prepare(
        `SELECT
          id,
          role,
          text,
          reasoning,
          tools_json AS toolsJson,
          items_json AS itemsJson,
          status,
          error,
          created_at AS createdAt
        FROM messages
        WHERE session_id = ?
        ORDER BY created_at, rowid`,
      )
      .all(sessionId) as StoredMessageRow[];

    return rows.map(
      ({ toolsJson, itemsJson, reasoning, status, error, id, ...message }) => ({
        id,
        ...message,
        reasoning: reasoning ?? undefined,
        ...(toolsJson !== null
          ? { toolCalls: parseJsonColumn<ToolCall[]>(toolsJson, id, "工具调用") }
          : {}),
        ...(itemsJson !== null
          ? {
              items: parseJsonColumn<NonNullable<StoredMessage["items"]>>(
                itemsJson,
                id,
                "消息项",
              ),
            }
          : {}),
        ...(status ? { status } : {}),
        ...(error ? { error } : {}),
      }),
    );
  }

  getProject(projectId: string): ProjectInfo | undefined {
    return this.database
      .prepare(
        "SELECT id, name, path, created_at AS createdAt FROM projects WHERE id = ?",
      )
      .get(projectId) as ProjectInfo | undefined;
  }

  projectByPath(path: string): ProjectInfo | undefined {
    return this.database
      .prepare(
        "SELECT id, name, path, created_at AS createdAt FROM projects WHERE path = ?",
      )
      .get(path) as ProjectInfo | undefined;
  }

  close(): void {
    if (this.isClosed) {
      return;
    }
    this.isClosed = true;
    this.database.close();
  }
}

function parseJsonColumn<Value>(
  value: string,
  messageId: string,
  columnName: string,
): Value {
  try {
    return JSON.parse(value) as Value;
  } catch {
    throw new Error(`消息 ${messageId} 的${columnName}数据已损坏`);
  }
}
