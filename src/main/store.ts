import Database from "better-sqlite3";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import type {
  ProjectInfo,
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
  createdAt: string;
}

export class DiscoStore {
  private readonly database: Database.Database;

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
        created_at TEXT NOT NULL
      );
    `);
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
        ORDER BY updated_at DESC`,
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

  appendMessage(sessionId: string, message: StoredMessage): void {
    this.database
      .prepare(
        `INSERT INTO messages (
          id, session_id, role, text, reasoning, tools_json, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        message.id,
        sessionId,
        message.role,
        message.text,
        message.reasoning ?? null,
        message.toolCalls ? JSON.stringify(message.toolCalls) : null,
        message.createdAt,
      );
    this.database
      .prepare("UPDATE sessions SET updated_at = ? WHERE id = ?")
      .run(message.createdAt, sessionId);
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
          created_at AS createdAt
        FROM messages
        WHERE session_id = ?
        ORDER BY created_at`,
      )
      .all(sessionId) as StoredMessageRow[];

    return rows.map(({ toolsJson, reasoning, ...message }) => ({
      ...message,
      reasoning: reasoning ?? undefined,
      toolCalls: toolsJson ? (JSON.parse(toolsJson) as ToolCall[]) : undefined,
    }));
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
    this.database.close();
  }
}
