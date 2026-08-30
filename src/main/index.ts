import { app, BrowserWindow, dialog, ipcMain, shell } from "electron";
import updater from "electron-updater";
import { join } from "node:path";
import { z } from "zod";
import { AgentHost } from "./host.js";
import { DiscoStore } from "./store.js";

const { autoUpdater } = updater;
const uuidSchema = z.string().uuid();
const backendSchema = z.enum(["codex", "claude", "opencode"]);
const runModeSchema = z.enum(["agent", "plan"]);
const approvalDecisionSchema = z.enum(["approved", "denied"]);
const rendererDevUrl = process.env.VITE_DEV_SERVER_URL;
const preloadPath = join(import.meta.dirname, "../preload/index.cjs");
const rendererPath = join(
  import.meta.dirname,
  "../../dist-renderer/index.html",
);

let mainWindow: BrowserWindow | undefined;
let host: AgentHost;

function secureNavigation(browserWindow: BrowserWindow): void {
  browserWindow.webContents.setWindowOpenHandler(({ url }) => {
    void shell.openExternal(url);
    return { action: "deny" };
  });
  browserWindow.webContents.on("will-navigate", (event, url) => {
    const isAllowed =
      url.startsWith("file:") || url.startsWith("http://127.0.0.1:5173");
    if (!isAllowed) {
      event.preventDefault();
    }
  });
}

function loadRenderer(browserWindow: BrowserWindow, hash?: string): void {
  if (rendererDevUrl) {
    const url = hash ? `${rendererDevUrl}#${hash}` : rendererDevUrl;
    void browserWindow.loadURL(url);
    return;
  }
  void browserWindow.loadFile(rendererPath, hash ? { hash } : undefined);
}

function createMainWindow(): void {
  mainWindow = new BrowserWindow({
    width: 1280,
    height: 800,
    minWidth: 960,
    minHeight: 640,
    backgroundColor: "#101312",
    titleBarStyle: "hiddenInset",
    webPreferences: {
      preload: preloadPath,
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  secureNavigation(mainWindow);
  loadRenderer(mainWindow);
}

ipcMain.handle("disco:projects", () => host.listProjects());
ipcMain.handle("disco:create-project", (_event, path: unknown) =>
  host.createProject(z.string().min(1).parse(path)),
);
ipcMain.handle("disco:sessions", (_event, projectId: unknown) =>
  host.listSessions(uuidSchema.parse(projectId)),
);
ipcMain.handle(
  "disco:create-session",
  (_event, projectId: unknown, backend: unknown) =>
    host.createSession(
      uuidSchema.parse(projectId),
      backendSchema.parse(backend),
    ),
);
ipcMain.handle("disco:messages", (_event, sessionId: unknown) =>
  host.messages(uuidSchema.parse(sessionId)),
);
ipcMain.handle(
  "disco:prompt",
  (_event, sessionId: unknown, text: unknown, mode: unknown) => {
    void host.prompt(
      uuidSchema.parse(sessionId),
      z.string().trim().min(1).max(100_000).parse(text),
      runModeSchema.parse(mode),
    );
  },
);
ipcMain.handle("disco:cancel", (_event, sessionId: unknown) =>
  host.cancel(uuidSchema.parse(sessionId)),
);
ipcMain.handle(
  "disco:approve",
  (_event, approvalId: unknown, decision: unknown) =>
    host.approve(
      uuidSchema.parse(approvalId),
      approvalDecisionSchema.parse(decision),
    ),
);
ipcMain.handle("disco:providers", () => host.providers());
ipcMain.handle("disco:about", () => ({
  dataPath: join(app.getPath("userData"), "disco.sqlite"),
  version: app.getVersion(),
}));
ipcMain.handle("disco:choose-directory", async () => {
  const result = await dialog.showOpenDialog({
    properties: ["openDirectory", "createDirectory"],
  });
  return result.filePaths[0] ?? null;
});
ipcMain.handle(
  "disco:choose-files",
  async (_event, withDirectories: unknown) => {
    const properties: Array<"openFile" | "openDirectory" | "multiSelections"> =
      withDirectories === true
        ? ["openFile", "openDirectory", "multiSelections"]
        : ["openFile", "multiSelections"];
    return (await dialog.showOpenDialog({ properties })).filePaths;
  },
);

app.whenReady().then(() => {
  host = new AgentHost(
    new DiscoStore(join(app.getPath("userData"), "disco.sqlite")),
    (event) => mainWindow?.webContents.send("disco:event", event),
  );
  createMainWindow();
  if (app.isPackaged && process.env.DISCO_DISABLE_AUTO_UPDATE !== "1") {
    void autoUpdater.checkForUpdatesAndNotify();
  }
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") {
    app.quit();
  }
});

app.on("activate", () => {
  if (BrowserWindow.getAllWindows().length === 0) {
    createMainWindow();
  }
});
