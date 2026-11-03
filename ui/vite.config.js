import { defineConfig } from "vite";

// 前端打包配置。Tauri 壳与浏览器兜底共用同一份 ui/。
// Tauri 需要固定的 dist 目录；浏览器壳（server 起服务）则直接读 dist。
export default defineConfig({
  // 用相对路径，产物能被 file:// 或任意子路径加载，浏览器壳也能直接用
  base: "./",
  build: {
    outDir: "dist",
    emptyOutDir: true,
  },
  server: {
    port: 1420,
    strictPort: true,
  },
  clearScreen: false,
});
