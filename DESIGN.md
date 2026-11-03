# MindModel 跨平台设计（开源版）

> 目标：一套代码，覆盖 Windows / macOS / Linux / 国产平台，输出"这台机器能跑什么模型、跑多快"的判定，
> 并据此完成下载、注册、启动。免费、开源、可离线。

## 一、结论先行：内核换 Rust，壳分两种

现在的 Swift 版本（`Sources/` 下 4 个文件，约 900 行）只能跑 macOS。要跨平台，
**内核必须重写为 Rust**；但真正有价值的部分（算法与数据模型）只占三分之一，移植成本可控。

| 层 | 现在（Swift/macOS） | 开源版 | 理由 |
|---|---|---|---|
| 硬件探测 | `Probe.swift` 190 行 | Rust `probe` crate，每平台一个实现 | sysctl/Metal 换成 IOKit、DXGI、sysfs、NVML |
| GGUF 解析 | `GGUF.swift` 330 行 | Rust `gguf` crate，逻辑 1:1 | 纯字节解析，无平台依赖 |
| 适配与打分 | `Advisor.swift` 160 行 | Rust `advisor` crate，公式 1:1 | 这是产品的核心资产，必须独立成库 |
| 模型目录 | `Catalog.swift` 230 行内嵌 | 外置 `models.toml` + 远程 JSON | 社区可 PR，不必改代码 |
| 界面 | SwiftUI | Web UI（同一份前端） | 两种壳共用 |

**关键判断：不要自己写推理引擎。** 推理交给后端抽象层，按平台挂不同实现。

## 二、仓库结构

```
mindmodel/
├── crates/
│   ├── core/            # 纯逻辑，无 I/O 副作用，可单元测试
│   │   ├── gguf.rs      # 头部解析：架构/量化/参数量/KV/分片/mmproj
│   │   ├── advisor.rs   # 需求=权重+KV+运行时；速度=带宽÷每token字节
│   │   ├── catalog.rs   # 模型清单（读 models.toml）
│   │   └── purpose.rs   # 用途门槛与打分
│   ├── probe/           # 硬件探测，按 target 条件编译
│   │   ├── probe_apple.rs      # sysctl + Metal working set
│   │   ├── probe_windows.rs    # DXGI + WMI + NVML
│   │   ├── probe_linux.rs      # sysfs + lspci + nvidia-smi/rocm-smi
│   │   └── probe_fallback.rs   # 只有 /proc 的平台（国产）
│   ├── backend/         # 推理后端 trait：available() / install() / run()
│   │   ├── llama_cpp.rs        # CPU/CUDA/Vulkan/ROCm/SYCL/Metal
│   │   ├── mlx.rs              # 仅 Apple
│   │   ├── ollama.rs           # 已有 Ollama 就直接用
│   │   └── external.rs         # 自定义命令
│   ├── cli/             # mindmodel 命令行：scan / advise / import / bench
│   └── server/          # 本地 HTTP：serve 前端 + OpenAI 兼容代理
├── ui/                  # 前端（Vite + 原生 JS 或 Preact），两种壳共用
├── shells/
│   ├── tauri/           # Win/macOS/Linux 桌面壳
│   └── browser/         # 无 GUI 平台：core 起服务，浏览器打开
├── data/models.toml     # 模型清单与实测速度库
└── .github/workflows/   # 构建矩阵
```

## 三、平台矩阵（诚实的覆盖度）

| 平台 | 探测 | 推理后端 | GUI | 状态判断 |
|---|---|---|---|---|
| macOS (arm64/x86_64) | Metal + sysctl | MLX、llama.cpp Metal | Tauri | 已验证（Swift 版实跑） |
| Windows x64 | DXGI + NVML | CUDA / Vulkan / CPU | Tauri | 需实机验证 |
| Linux x64 | sysfs + NVML | CUDA / ROCm / Vulkan | Tauri | 需实机验证 |
| 麒麟/统信 aarch64（鲲鹏/飞腾） | /proc + sysfs | llama.cpp CPU(NEON) | CLI + 浏览器 | 需实机验证 |
| 龙芯 LoongArch64 | /proc + sysfs | llama.cpp CPU(LSX/LASX) | CLI + 浏览器 | **风险最高**，Rust target 为 tier-2，需交叉编译链 |
| 海光 x86_64 | 同 Linux x64 | CPU / DCU(ROCm 变体) | CLI + 浏览器 | 需实机验证 |

**必须先说清的两条底线：**

1. **国产平台的瓶颈不在界面，在推理后端。** llama.cpp 的 LoongArch SIMD 支持成熟度不足，
   实测可能只有同代 x86 的三成；这不是本项目能解决的，只能给出实测数据、不让用户误判。
2. **"支持"= 有二进制且跑过实测，不等于"优化好"。** 界面上要区分「未验证 / 可运行 / 已实测」三档，
   不能对国产平台含糊其辞——那是最容易伤害用户信任的地方。

## 四、推理后端抽象

```rust
trait Backend {
    fn id(&self) -> &'static str;
    fn available(&self) -> bool;                 // 是否已安装/可见
    fn accel(&self) -> AccelKind;                // Metal/CUDA/ROCm/Vulkan/CPU
    fn install(&self, progress: &mut dyn FnMut(f32)) -> Result<()>;
    fn run(&self, model: &Path, ctx: u32) -> Result<Session>;
    fn measure_bandwidth(&self) -> Result<f64>;  // 各平台探测方式不同
}
```

优先级：**已有 Ollama → 直接复用**（不重复造下载器）；否则按平台推荐 llama.cpp / MLX。

## 五、核心算法（跨平台不变的部分）

这是真正值得开源的那部分，也是与"按显存推荐"的工具区分开的地方：

```
预算      = min(Metal/DXGI 建议工作集, 0.80 × 物理内存)
需求      = 权重 + KV + 运行时(1.6 GB)
KV        = 2 × 层数 × KV头数 × head_dim × 2B × 上下文
速度      = 实测带宽 × 0.45 ÷ (权重 × 激活占比 + 0.25)
判定      = 需求/预算 ≤ 40%(余量足) / 72%(流畅) / 92%(可运行) / 115%(偏紧) / 否则超限
用途门槛  = 写作 12 / 编码 15 / 推理 6 / 看图 12 / 长文 8 / 常驻 30 tok/s
打分      = 参数量^0.8 × min(1, 速度/参考速度)^0.8
```

**三条不能妥协的原则**（Swift 版踩过的坑，已固化为设计约束）：

1. MoE 的激活占比不能钳下限——钳制会让 30B-A3B 被当成 6B，系统性高估大 dense 模型。
2. GGUF 数组必须按真实元素个数跳过——分词表 12.8 万条，截断即全表错位。
3. 估算值必须可被实测覆盖，且两者在界面上分色显示。

## 五之二、任务级匹配的合并语义（多选）

单一"用途"不够用：真实场景是一组任务并行。多选合并规则写死如下（Rust `task.rs` 与 Swift `TaskBlend` 逐条对齐，两边实跑结果必须逐字相同）：

| 维度 | 合并方式 | 理由 |
|---|---|---|
| 七维权重 | 每个任务先归一化到 sum=1，再取均值 | 原始权重之和不同的任务混在一起，等于偷偷给某些维度加码 |
| 上下文门槛 | 取最大 | 组合里有一个要 64K，就必须能撑 64K |
| 速度门槛 | 取最高 | 组合里有一个要 28 tok/s，就按 28 筛 |
| 中文门槛 | 任一任务以中文为主即生效 | 放宽会让中文语感 3.0 的模型拿下中文写作 |
| 模态门槛 | 任一任务需看图，则排除纯文本模型 | 图表理解不是"权重高一点"，而是硬需求 |
| 家族修正 | 按各任务取均值 | 否则"只要选了编码，写作就被整体腰斩" |

**门槛必须取最严，不能取平均**：取平均时，"写论文 + 看图表"会被一个两样都不行的中庸模型夺冠。

筛选账目必须闭合且显式标注放宽：`候选 → 模态 → 容量 → 上下文 → 速度 → 中文 → 通过`。
某道门槛把候选砍光时会自动退回上一级（否则用户永远拿不到结果），此时账目里标 `(已放宽)` 并给出警告——
不能出现"速度 -34 … 通过 19"这种自相矛盾的数字。

**候选池只按模态收窄，不按类别收窄**：多模态模型同样是称职的文本模型
（Qwen3-VL 30B-A3B 的写作与中文都不弱），按 `.vision` 分类把文本任务的候选池砍到 34 个是错的，会白白丢掉好候选。
只有"必须看图"的任务才筛 `vision > 1.5`。

## 五之三、可复现的验证手段（无 GUI 依赖）

- 逻辑层与 UI 分离，`Advisor`/`TaskBlend` 是纯函数，可编译成命令行校验器直接打印结果；
  Rust 侧有 5 条断言钉住与 Swift 的首选一致（`task_picks_match_swift_side`）。
- `MM_TAB=<tab>` 让应用直落到指定页签；`MM_SNAPSHOT=<path>` 用 `ImageRenderer` 离屏渲染整页为 PNG 后退出。
  不依赖窗口焦点与录屏权限，CI 里可用于视觉回归。
  （注意：`ScrollView` 在 `ImageRenderer` 里不出内容，故页面内容抽为 `PageStack` 以便绕开。）

## 六、许可证与治理

- **代码许可：Apache-2.0**。含专利授权条款，企业、高校、军工配套单位采用时法务阻力最小；MIT 缺专利条款，在国产化替代场景容易卡住。
- **模型清单**：数据文件单独声明来源与许可（各模型自带 license，不随本项目授权）。
- **不内置任何模型权重**，只提供清单与元数据，规避分发风险。
- **CLA 不要求**，用 DCO 即可，降低社区贡献门槛。

## 七、路线

| 阶段 | 内容 | 验收 |
|---|---|---|
| P0（已有） | macOS Swift 版可用 | 本机跑通：体检 → 推荐 → GGUF 导入 → 实测 |
| P1 | Rust core 移植 + CLI | `mindmodel advise` 与 Swift 版输出一致（同机对比） |
| P2 | Windows/Linux 桌面壳 | 三平台各出一份二进制，跑同一套自检 |
| P3 | 社区化：models.toml 外置、文档、CI | 第三方能 PR 加一个模型 |
| P4 | 国产平台实机验证 | 出实测表，标注「已实测」而非「支持」 |

## 八、打包现实

- Windows 未签名会触发 SmartScreen 警告，需代码签名证书（约 300–500 美元/年）或文档说明"更多信息→仍要运行"。
- macOS 无公证则提示"无法验证开发者"，需 Apple Developer 账号（99 美元/年）；本地自用可 `xattr -d com.apple.quarantine`。
- Linux 用 `.tar.gz` + `.deb` + AUR，不需要签名。
- **国产平台只发 CLI + 源码构建脚本**，不承诺 GUI 二进制——依赖 WebKitGTK 版本地狱。
