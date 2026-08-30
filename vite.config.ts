import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  server: { host: "127.0.0.1", port: 5173, strictPort: true },
  root: "src/renderer",
  base: "./",
  build: { outDir: "../../dist-renderer", emptyOutDir: true },
  test: { include: ["../main/**/*.test.ts"], environment: "node" },
});
