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
const localeSchema = z.enum(["zh-CN", "en-US"]).optional();
const modelIdSchema = z.string().trim().min(1).max(200).optional();
const reasoningEffortSchema = z
  .enum(["minimal", "low", "medium", "high", "xhigh", "max", "ultra", "persistent"])
  .optional();
const sandboxModeSchema = z
  .enum(["read-only", "workspace-write", "danger-full-access"])
  .optional();
const rendererDevUrl = process.env.VITE_DEV_SERVER_URL;
const preloadPath = join(import.meta.dirname, "../preload/index.cjs");
const rendererPath = join(
  import.meta.dirname,
  "../../dist-renderer/index.html",
);

let mainWindow: BrowserWindow | undefined;
let host: AgentHost | undefined;
let store: DiscoStore | undefined;
let isQuitting = false;

function getHost(): AgentHost {
  if (!host) {
    throw new Error("Disco 主进程尚未完成初始化");
  }
  return host;
}

function assertTrustedRenderer(event: Electron.IpcMainInvokeEvent): void {
  if (event.sender !== mainWindow?.webContents) {
    throw new Error("拒绝来自未知窗口的请求");
  }
}

function isRendererUrl(url: string): boolean {
  try {
    const parsedUrl = new URL(url);
    if (rendererDevUrl) {
      return parsedUrl.origin === new URL(rendererDevUrl).origin;
    }
    return (
      parsedUrl.protocol === "file:" &&
      decodeURIComponent(parsedUrl.pathname) === rendererPath
    );
  } catch {
    return false;
  }
}

function secureNavigation(browserWindow: BrowserWindow): void {
  browserWindow.webContents.setWindowOpenHandler(({ url }) => {
    try {
      const protocol = new URL(url).protocol;
      if (protocol === "http:" || protocol === "https:") {
        void shell.openExternal(url).catch(() => {});
      }
    } catch {
      // Invalid URLs stay blocked.
    }
    return { action: "deny" };
  });
  browserWindow.webContents.on("will-navigate", (event, url) => {
    if (!isRendererUrl(url)) {
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

ipcMain.handle("disco:projects", (event) => {
  assertTrustedRenderer(event);
  return getHost().listProjects();
});
ipcMain.handle(
  "disco:create-project",
  (event, path: unknown, locale: unknown) => {
  assertTrustedRenderer(event);
    return getHost().createProject(
      z.string().min(1).parse(path),
      localeSchema.parse(locale),
    );
  },
);
ipcMain.handle("disco:sessions", (event, projectId: unknown) => {
  assertTrustedRenderer(event);
  return getHost().listSessions(uuidSchema.parse(projectId));
});
ipcMain.handle(
  "disco:create-session",
  (
    event,
    projectId: unknown,
    backend: unknown,
    modelId: unknown,
    reasoningEffort: unknown,
    sandboxMode: unknown,
    locale: unknown,
  ) => {
    assertTrustedRenderer(event);
    return getHost().createSession(
      uuidSchema.parse(projectId),
      backendSchema.parse(backend),
      modelIdSchema.parse(modelId),
      reasoningEffortSchema.parse(reasoningEffort),
      sandboxModeSchema.parse(sandboxMode),
      localeSchema.parse(locale),
    );
  },
);
ipcMain.handle("disco:messages", (event, sessionId: unknown) => {
  assertTrustedRenderer(event);
  return getHost().messages(uuidSchema.parse(sessionId));
});
ipcMain.handle(
  "disco:prompt",
  async (
    event,
    sessionId: unknown,
    text: unknown,
    mode: unknown,
    locale: unknown,
  ) => {
    assertTrustedRenderer(event);
    await getHost().prompt(
      uuidSchema.parse(sessionId),
      z.string().trim().min(1).max(100_000).parse(text),
      runModeSchema.parse(mode),
      localeSchema.parse(locale),
    );
  },
);
ipcMain.handle("disco:cancel", (event, sessionId: unknown) => {
  assertTrustedRenderer(event);
  return getHost().cancel(uuidSchema.parse(sessionId));
});
ipcMain.handle(
  "disco:approve",
  (event, approvalId: unknown, decision: unknown) => {
    assertTrustedRenderer(event);
    return getHost().approve(
      uuidSchema.parse(approvalId),
      approvalDecisionSchema.parse(decision),
    );
  },
);
ipcMain.handle("disco:providers", (event, locale: unknown) => {
  assertTrustedRenderer(event);
  return getHost().providers(localeSchema.parse(locale));
});

ipcMain.handle("disco:about", (event) => {
  assertTrustedRenderer(event);
  return {
    dataPath: join(app.getPath("userData"), "disco.sqlite"),
    version: app.getVersion(),
  };
});
ipcMain.handle("disco:choose-directory", async (event) => {
  assertTrustedRenderer(event);
  const result = await dialog.showOpenDialog({
    properties: ["openDirectory", "createDirectory"],
  });
  return result.filePaths[0] ?? null;
});
ipcMain.handle(
  "disco:choose-files",
  async (event, withDirectories: unknown) => {
    assertTrustedRenderer(event);
    const properties: Array<"openFile" | "openDirectory" | "multiSelections"> =
      z.boolean().parse(withDirectories)
        ? ["openFile", "openDirectory", "multiSelections"]
        : ["openFile", "multiSelections"];
    return (await dialog.showOpenDialog({ properties })).filePaths;
  },
);

app.whenReady().then(() => {
  store = new DiscoStore(join(app.getPath("userData"), "disco.sqlite"));
  host = new AgentHost(
    store,
    (event) => mainWindow?.webContents.send("disco:event", event),
  );
  createMainWindow();
  if (app.isPackaged && process.env.DISCO_DISABLE_AUTO_UPDATE !== "1") {
    void autoUpdater.checkForUpdatesAndNotify().catch(() => {});
  }
});

app.on("before-quit", (event) => {
  if (isQuitting) {
    return;
  }
  event.preventDefault();
  isQuitting = true;
  void (async () => {
    await host?.shutdown();
    store?.close();
    app.quit();
  })();
});

app.on("will-quit", () => {
  store?.close();
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
