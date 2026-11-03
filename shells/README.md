# 跨平台壳（骨架）

这个目录是 P2 阶段的骨架：代码结构就位，**三平台实机验证尚未开始**。

## 现状

| 目录 | 内容 | 状态 |
|---|---|---|
| `tauri/src-tauri/` | Tauri 壳的 Rust 侧，把 core/probe/backend 暴露成 `scan` / `engines` 两个 command | 骨架，能编译的依赖未在本机装（需 `cargo install tauri-cli`） |
| `browser/` | 无 GUI 平台（国产/服务器）的兜底：core 起本地 HTTP，浏览器打开 | 未开始 |

## 为什么是骨架而不是成品

DESIGN.md 第三节的平台矩阵已经写明：跨平台的瓶颈不在界面，在推理后端与实机验证。
"能编译"不等于"支持"，国产平台尤其如此。因此这里只搭结构，不虚标覆盖度。

## 后续（P2/P3）

1. 前端 `ui/`：一份 Vite + 原生 JS，两种壳（Tauri / 浏览器）共用。算法全走 Rust command，前端不重算。
2. `tauri build` 出 Win/macOS/Linux 三份二进制，跑同一套自检。
3. `browser/`：`mindmodel serve` 起服务，`/api/scan` 返回 JSON，浏览器渲染。

## 现在能用的仍是两套

- **macOS 桌面**：`./build.sh` → `build/MindModel.app`（已验证）
- **命令行**：`rust/crates/cli` → `mindmodel scan|advise|task|parse|list|engines`（已验证）
