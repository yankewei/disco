import Database from "better-sqlite3";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import type { ProjectInfo, SessionInfo, StoredMessage } from "../shared/types.js";

export class DiscoStore {
  private readonly db: Database.Database;
  constructor(path: string) {
    mkdirSync(dirname(path), { recursive: true }); this.db = new Database(path); this.db.pragma("journal_mode = WAL");
    this.db.exec("CREATE TABLE IF NOT EXISTS projects (id TEXT PRIMARY KEY, name TEXT NOT NULL, path TEXT NOT NULL UNIQUE, created_at TEXT NOT NULL); CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, backend TEXT NOT NULL, backend_session_id TEXT, title TEXT NOT NULL, updated_at TEXT NOT NULL); CREATE TABLE IF NOT EXISTS messages (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, role TEXT NOT NULL, text TEXT NOT NULL, reasoning TEXT, tools_json TEXT, created_at TEXT NOT NULL);");
  }
  listProjects() { return this.db.prepare("SELECT id, name, path, created_at AS createdAt FROM projects ORDER BY created_at DESC").all() as ProjectInfo[]; }
  createProject(project: ProjectInfo) { this.db.prepare("INSERT INTO projects (id, name, path, created_at) VALUES (@id, @name, @path, @createdAt)").run(project); }
  deleteProject(id: string) { this.db.transaction(() => { this.db.prepare("DELETE FROM messages WHERE session_id IN (SELECT id FROM sessions WHERE project_id = ?)").run(id); this.db.prepare("DELETE FROM sessions WHERE project_id = ?").run(id); this.db.prepare("DELETE FROM projects WHERE id = ?").run(id); })(); }
  listSessions(projectId?: string) { const sql = `SELECT id AS sessionId, project_id AS projectId, backend, backend_session_id AS backendSessionId, title, updated_at AS updatedAt FROM sessions ${projectId ? "WHERE project_id = ?" : ""} ORDER BY updated_at DESC`; return (projectId ? this.db.prepare(sql).all(projectId) : this.db.prepare(sql).all()) as SessionInfo[]; }
  getSession(id: string) { return this.db.prepare("SELECT id AS sessionId, project_id AS projectId, backend, backend_session_id AS backendSessionId, title, updated_at AS updatedAt FROM sessions WHERE id = ?").get(id) as SessionInfo | undefined; }
  createSession(session: SessionInfo) { this.db.prepare("INSERT INTO sessions (id, project_id, backend, backend_session_id, title, updated_at) VALUES (@sessionId, @projectId, @backend, @backendSessionId, @title, @updatedAt)").run({ ...session, backendSessionId: session.backendSessionId ?? null }); }
  updateSession(id: string, backendSessionId: string) { this.db.prepare("UPDATE sessions SET backend_session_id = ?, updated_at = ? WHERE id = ?").run(backendSessionId, new Date().toISOString(), id); }
  deleteSession(id: string) { this.db.transaction(() => { this.db.prepare("DELETE FROM messages WHERE session_id = ?").run(id); this.db.prepare("DELETE FROM sessions WHERE id = ?").run(id); })(); }
  appendMessage(sessionId: string, message: StoredMessage) { this.db.prepare("INSERT INTO messages (id, session_id, role, text, reasoning, tools_json, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)").run(message.id, sessionId, message.role, message.text, message.reasoning ?? null, message.toolCalls ? JSON.stringify(message.toolCalls) : null, message.createdAt); this.db.prepare("UPDATE sessions SET updated_at = ? WHERE id = ?").run(message.createdAt, sessionId); }
  messages(sessionId: string) { const rows = this.db.prepare("SELECT id, role, text, reasoning, tools_json AS toolsJson, created_at AS createdAt FROM messages WHERE session_id = ? ORDER BY created_at").all(sessionId) as Array<StoredMessage & { toolsJson?: string }>; return rows.map(({ toolsJson, ...row }) => ({ ...row, toolCalls: toolsJson ? JSON.parse(toolsJson) : undefined })); }
  getProject(id: string) { return this.db.prepare("SELECT id, name, path, created_at AS createdAt FROM projects WHERE id = ?").get(id) as ProjectInfo | undefined; }
  projectByPath(path: string) { return this.db.prepare("SELECT id, name, path, created_at AS createdAt FROM projects WHERE path = ?").get(path) as ProjectInfo | undefined; }
  close() { this.db.close(); }
}
