# 跨平台壳

一套前端（`ui/`）+ 两套后端（Tauri 桌面 / server 浏览器），覆盖从桌面到无 GUI 平台。

## 现状

| 目录 | 内容 | 状态 |
|---|---|---|
| `tauri/src-tauri/` | Tauri 壳 Rust 侧，暴露 `scan`/`engines`/`advise`/`models` 四个 command | ✅ 本机 `cargo check` 与 `cargo tauri build` 通过 |
| `ui/` | Vite + 原生 JS 前端，调 Tauri command 或本地 HTTP，两种壳共用 | ✅ 本机 `npm run build` 通过 |
| `browser/` | 无 GUI 平台的浏览器兜底（`mindmodel-serve` 本地 HTTP） | ✅ 本机端到端跑通（scan/engines/models/advise/task + 静态文件） |

## 本机已验证

- macOS：`cargo tauri build` 产出 11MB 的 `MindModel.app` 与 `mindmodel-tauri` 二进制。
  （dmg 打包在本机沙箱里因 `hdiutil` 无法挂载镜像而失败，属环境限制；CI 的 macOS runner 无此问题。）

## 三平台安装包（靠 CI 产出）

本机 macOS 无法交叉编译 Windows/Linux 二进制，所以 `.exe` / `.deb` / `.AppImage` / `.dmg`
由 `.github/workflows/release.yml` 在真正的 `windows-latest` / `ubuntu-latest` / `macos-latest`
runner 上编译，产物上传为 artifact。推送 `main` 或打 `v*` tag 即触发。

下载方式：仓库 Actions 页 → 对应 run → Artifacts。

## 本地构建（macOS）

```bash
# 一次性：装 tauri-cli + 前端依赖
cargo install tauri-cli --version "^2" --locked
cd ui && npm install && cd ..

# 构建（自动先 npm run build 再编译）
cd shells/tauri/src-tauri
cargo tauri build
# 产物：target/release/bundle/macos/MindModel.app
```

## 覆盖度（诚实标注）

- macOS：✅ 本机实跑可编译出应用。
- Windows / Linux：代码就位、CI 会编译，但**尚未在真实硬件上打开运行过**。
  探测层（DXGI/NVML、sysfs/NVML）与打包结果都需要真机点开验证，这一步还没做。
- 国产平台（鲲鹏/飞腾/龙芯/海光）：仍未开始，见 DESIGN.md 平台矩阵。
