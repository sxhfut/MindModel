# browser 壳（无 GUI 平台的兜底路径）

麒麟/统信、龙芯、海光、服务器等没有图形界面或不便装 Tauri 的平台，
用浏览器即可获得与桌面版一致的能力：所有算法仍在本地 Rust 侧跑，不联网。

## 原理

`mindmodel-serve` 起一个本地 HTTP 服务（只监听 `127.0.0.1`，不对外网开放），
浏览器打开 `http://127.0.0.1:8462`，加载与桌面版同一套前端（`ui/`），
通过 `/api/*` 拿 JSON。前端无需感知是桌面还是浏览器。

```
浏览器 ──http──> mindmodel-serve ──> core/probe/backend（本地算法）
                                      ├─ /api/scan     硬件体检 + 带宽实测
                                      ├─ /api/engines  推理后端检测
                                      ├─ /api/models   模型清单
                                      ├─ /api/advise   按用途推荐
                                      └─ /api/task     按角色/任务推荐
```

## 构建与运行

```bash
# 1. 构建前端（产出 ui/dist）
cd ui && npm install && npm run build && cd ..

# 2. 编译并启动服务（默认端口 8462）
cd rust && cargo run -p mindmodel-server
# 或指定端口：
cargo run -p mindmodel-server -- 9000

# 3. 打开浏览器
# http://127.0.0.1:8462
```

发布版二进制：`cargo build -p mindmodel-server --release` →
`rust/target/release/mindmodel-serve`。

## API

| 端点 | 说明 |
|---|---|
| `GET /api/health` | 存活探针 |
| `GET /api/scan` | 硬件体检（芯片/预算/带宽/磁盘/可承载候选数） |
| `GET /api/engines` | 推理后端检测（Ollama/llama.cpp/MLX…） |
| `GET /api/models` | 内置模型清单（79 条） |
| `GET /api/advise?purpose=coding&ctx=16384` | 按用途推荐 |
| `GET /api/task?tasks=paper,code` | 按任务多选推荐 |

`purpose`：`writing` / `coding` / `reasoning` / `vision` / `longdoc` / `alwayson`
`tasks`：`paper,lit,code,debug,data,review,teach,trans,affect,daily,vision,summary`（逗号分隔可多选）

## 设计取舍（诚实标注）

- **零外部依赖**：HTTP 用 `std::net::TcpListener`，JSON 手写序列化，与项目
  "零外部依赖、可离线编译"的原则一致。代价是并发用每连接一线程，单机自用足够。
- **只监听回环地址**：探测结果含本机硬件信息，绝不对外网开放。多机共享需自行反代加鉴权。
- **静态文件从 `ui/dist` 加载**：用 `MM_UI_DIST` 环境变量可覆盖路径；找不到时
  回退到一段内联 API 索引页，不影响纯 API 调用。
- **国产平台（鲲鹏/飞腾/龙芯/海光）**：本壳是它们最可行的入口——只要 `std::net`
  与 `probe` 的 CPU 兜底能跑，浏览器壳就能工作；显卡加速需等 llama.cpp 对
  相应 SIMD（LoongArch LSX/LASX 等）成熟，见 DESIGN.md 平台矩阵。
