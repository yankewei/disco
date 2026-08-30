import { contextBridge, ipcRenderer } from "electron";
import type { AgentEvent, DiscoAPI } from "../shared/types.js";

const api: DiscoAPI = {
  listProjects: () => ipcRenderer.invoke("disco:projects"),
  createProject: (path) => ipcRenderer.invoke("disco:create-project", path),
  listSessions: (projectId) => ipcRenderer.invoke("disco:sessions", projectId),
  createSession: (projectId, backend) =>
    ipcRenderer.invoke("disco:create-session", projectId, backend),
  loadMessages: (sessionId) => ipcRenderer.invoke("disco:messages", sessionId),
  prompt: (sessionId, text, mode) =>
    ipcRenderer.invoke("disco:prompt", sessionId, text, mode),
  cancel: (sessionId) => ipcRenderer.invoke("disco:cancel", sessionId),
  approve: (approvalId, decision) =>
    ipcRenderer.invoke("disco:approve", approvalId, decision),
  providers: () => ipcRenderer.invoke("disco:providers"),
  about: () => ipcRenderer.invoke("disco:about"),
  chooseDirectory: () => ipcRenderer.invoke("disco:choose-directory"),
  chooseFiles: (withDirectories) =>
    ipcRenderer.invoke("disco:choose-files", withDirectories),
  onEvent: (listener) => {
    const handler = (_event: Electron.IpcRendererEvent, event: AgentEvent) =>
      listener(event);
    ipcRenderer.on("disco:event", handler);
    return () => ipcRenderer.removeListener("disco:event", handler);
  },
};

contextBridge.exposeInMainWorld("disco", api);
