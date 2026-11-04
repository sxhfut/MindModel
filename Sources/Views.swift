import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 视觉组件

enum T {
    static let card = Color.primary.opacity(0.055)
    static let line = Color.primary.opacity(0.10)
    static let accent = Color(red: 0.42, green: 0.55, blue: 0.98)
    static let good = Color(red: 0.30, green: 0.78, blue: 0.62)
    static let warn = Color(red: 0.95, green: 0.68, blue: 0.32)
    static let bad = Color(red: 0.93, green: 0.42, blue: 0.42)
}

struct Card<C: View>: View {
    var pad: CGFloat = 14
    @ViewBuilder var content: C
    var body: some View {
        content
            .padding(pad)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(T.card))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(T.line, lineWidth: 0.7))
    }
}

struct Badge: View {
    let text: String
    var color: Color = T.accent
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .background(color.opacity(0.16))
            .foregroundStyle(color)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.30), lineWidth: 0.6))
    }
}

func fitColor(_ l: FitLevel) -> Color {
    switch l {
    case .plenty: return T.good
    case .smooth: return Color(red: 0.42, green: 0.70, blue: 0.96)
    case .ok: return Color(red: 0.62, green: 0.62, blue: 0.70)
    case .tight: return T.warn
    case .tooHeavy: return T.bad
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    var sub: String = ""
    var tint: Color = .primary
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(tint)
                if !sub.isEmpty {
                    Text(sub).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct KeyRow: View {
    let k: String
    let v: String
    var body: some View {
        HStack(alignment: .top) {
            Text(k).font(.system(size: 12.5)).foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(v).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
    }
}

/// 小标题加一句说明。说明文字比标题长是常态，所以给足两行以上，
/// 不要在窄栏里把话截断——截断的说明等于没写。
struct Bullet: View {
    let head: String
    let detail: String
    init(_ head: String, _ detail: String) {
        self.head = head
        self.detail = detail
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(head).font(.system(size: 11.5, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 搜索框。离屏渲染画不了 AppKit 的文本输入控件，会整块涂成黄色占位，
/// 所以截图模式下换成长得一样的静态框，别的路径不改。
struct SearchBox: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat = 150
    @EnvironmentObject var s: AppState

    var body: some View {
        Group {
            if s.snapshot {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10))
                    Text(text.isEmpty ? placeholder : text).font(.system(size: 11))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .frame(height: 21)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(T.line, lineWidth: 0.7))
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
            }
        }
        .frame(width: width)
    }
}

struct SectionHead: View {
    let title: String
    var sub: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 15, weight: .semibold))
            if !sub.isEmpty {
                Text(sub).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 页面容器

/// 页头 + 当前页签内容。抽出来是为了让离屏快照（MM_SNAPSHOT）能绕开 ScrollView
/// 直接渲染——ScrollView 在 ImageRenderer 里不出内容，会把整屏渲染成空白。
struct PageStack: View {
    @EnvironmentObject var s: AppState
    var scrolls = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Header()
            switch s.tab {
            case .overview: OverviewView()
            case .hardware: HardwareView()
            case .recommend: RecommendView()
            case .task: TaskView()
            case .installed: InstalledView()
            case .online: OnlineModelsView()
            case .importGGUF: GGUFView()
            case .bench: BenchView()
            case .chat: ChatView()
            case .agent: AgentView()
            }
            Spacer(minLength: 20)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 根视图

struct RootView: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        HStack(spacing: 0) {
            Rail()
            Divider().opacity(0.5)
            ScrollView {
                PageStack()
            }
        }
        .background(LinearGradient(colors: [T.accent.opacity(0.05), Color.clear],
                                   startPoint: .topLeading, endPoint: .center))
        .overlay(alignment: .bottom) {
            if let t = s.toast {
                Text(t)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(T.line))
                    .padding(.bottom, 18)
                    .transition(.opacity)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                            withAnimation { s.toast = nil }
                        }
                    }
            }
        }
    }
}

struct Rail: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 1) {
                Text("MindModel").font(.system(size: 15, weight: .bold, design: .rounded))
                Text("本机模型顾问").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 22)
            .padding(.bottom, 14)

            ForEach(AppState.Tab.allCases) { t in
                Button {
                    withAnimation(.easeOut(duration: 0.12)) { s.tab = t }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: t.icon)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 15)
                        Text(t.rawValue).font(.system(size: 12.5, weight: s.tab == t ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(s.tab == t ? T.accent.opacity(0.16) : Color.clear))
                    .foregroundStyle(s.tab == t ? T.accent : Color.primary.opacity(0.78))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 7)
            }

            Spacer(minLength: 8)

            VStack(alignment: .leading, spacing: 4) {
                Text(s.hw.chip).font(.system(size: 10.5, weight: .semibold))
                Text("\(String(format: "%.0f", s.hw.ramGB)) GB 统一内存 · \(s.hw.gpuCores) GPU 核")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Text("可用预算 \(String(format: "%.0f", s.budgetGB)) GB")
                    .font(.system(size: 10)).foregroundStyle(T.accent)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 16)
        }
        .frame(width: 196)
        .background(Color.primary.opacity(0.025))
    }
}

struct Header: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(s.tab.rawValue).font(.system(size: 24, weight: .bold, design: .rounded))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if s.pullTag != nil {
                PullProgressBar()
            } else if let b = s.busy {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(b).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.bottom, 2)
    }

    var subtitle: String {
        switch s.tab {
        case .overview: return "按真实硬件给出可用模型清单，速度可实测"
        case .hardware: return "统一内存、Metal 工作集与实测带宽"
        case .recommend: return "上下文 \(s.contextTokens / 1024)K 下的适配判定与速度估算"
        case .task: return "按你的角色与具体任务，在跑得动的模型里挑最合用的"
        case .installed: return "检测本机推理引擎与已下载模型"
        case .online: return "搜索 HuggingFace 的 GGUF 模型，清单外也能找"
        case .importGGUF: return "任意 .gguf 均可导入，无模型白名单"
        case .bench: return "跳过估算，直接让 Ollama 跑一次"
        case .chat: return "用装好的模型直接对话，可带图片"
        case .agent: return "让模型动手：读文件、搜代码、写文件、跑命令"
        }
    }
}

// MARK: - 拉取进度

/// 顶部常驻的模型下载进度条。放在 Header 的 busy 位置，任意页签都能看到。
/// 断点续传由 Ollama 原生保证：中断后已下载层保留，重新拉取只补缺失部分。
struct PullProgressBar: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if s.pullVerifying {
                        ProgressView().controlSize(.mini)
                        Text("校验已下载层…（断点续传）")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    } else if let layer = s.pullLayer {
                        Text(layer.hash.prefix(8))
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        if !layer.done.isEmpty {
                            Text("\(layer.done)/\(layer.total)")
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                        if !layer.speed.isEmpty {
                            Text(layer.speed).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                        if !layer.eta.isEmpty {
                            Text("剩 \(layer.eta)").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(s.busy ?? "拉取中…").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.10))
                        Capsule()
                            .fill(T.accent)
                            .frame(width: max(4, geo.size.width * min(1.0, s.pullLayer?.pct ?? 0)))
                    }
                }
                .frame(width: 150, height: 5)
            }
            Button {
                s.cancelPull()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("取消拉取（已下载部分保留，可续传）")
        }
    }
}

// MARK: - 拉取按钮

/// 统一的「拉取」按钮。该 tag 正在拉取时显示「拉取中」并禁止重复点击；
/// 拉取是 Ollama 原生断点续传，中断后重新点即可续传，不会重下。
struct PullButton: View {
    @EnvironmentObject var s: AppState
    let tag: String
    var prominent = false

    var body: some View {
        if s.pullTag == tag {
            Button {
                s.cancelPull()
            } label: {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("拉取中").font(.system(size: 11.5))
                }
            }
            .buttonStyle(.bordered).controlSize(.small)
            .help("正在拉取 \(tag)。点击取消（已下载层保留）")
        } else {
            if prominent {
                Button("拉取") { s.runPull(tag) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(s.pullTag != nil)
                    .help("ollama pull \(tag)")
            } else {
                Button("拉取") { s.runPull(tag) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(s.pullTag != nil)
                    .help("ollama pull \(tag)")
            }
        }
    }
}

// MARK: - 文生图后端按钮

/// 图像模型的后端引导按钮。Ollama 跑不了文生图，需要 ComfyUI 或 stable-diffusion.cpp。
/// 已装则引导去引擎页查看，未装则给安装入口，不虚标「点一下出图」。
struct ImageBackendButton: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        if s.hasImageBackend {
            let names = s.imageBackends.map { $0.name }.joined(separator: " / ")
            Button("后端已就绪") {
                s.tab = .installed
            }
            .buttonStyle(.bordered).controlSize(.small)
            .help("已检测到 \(names)，去「已装与引擎」查看")
        } else {
            Menu {
                Button("安装 ComfyUI") {
                    if let u = URL(string: "https://www.comfy.org") { NSWorkspace.shared.open(u) }
                }
                Button("安装 stable-diffusion.cpp") {
                    if let u = URL(string: "https://github.com/leejet/stable-diffusion.cpp") { NSWorkspace.shared.open(u) }
                }
            } label: {
                Text("需图后端")
                    .font(.system(size: 11.5))
                    .foregroundStyle(T.warn)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Ollama 不跑文生图；需先装 ComfyUI 或 stable-diffusion.cpp 作为独立后端")
        }
    }
}

// MARK: - 概览

struct OverviewView: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                MetricCard(title: "权重预算", value: String(format: "%.0f GB", s.budgetGB),
                           sub: "Metal 建议工作集 \(String(format: "%.0f", s.hw.metalWorkingSetGB)) GB",
                           tint: T.accent)
                MetricCard(title: "实测内存带宽", value: s.bandwidth.map { String(format: "%.0f GB/s", $0) } ?? "待测",
                           sub: "决定 decode 速度上限", tint: s.bandwidth == nil ? .secondary : T.good)
                MetricCard(title: "建议档位", value: s.sweetSpot,
                           sub: s.fitCount == Catalog.all.count
                                ? "全部 \(Catalog.all.count) 个候选装得下"
                                : "\(s.fitCount)/\(Catalog.all.count) 个候选可承载",
                           tint: T.good)
                MetricCard(title: "磁盘可用", value: String(format: "%.0f GB", s.hw.diskFreeGB),
                           sub: "共 \(String(format: "%.0f", s.hw.diskTotalGB)) GB", tint: .primary)
            }

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHead(title: "首选三个", sub: "按参数规模 × 适配余量排序，非声望排序")
                    ForEach(s.ranked.prefix(3)) { a in
                        ModelRow(advice: a, compact: false)
                    }

                    SectionHead(title: "本机模型盘", sub: "已装多少、占多少、有没有该清的")
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 16) {
                                stat("已装", "\(s.installed.filter { !s.isCloud($0) }.count) 个")
                                stat("占用", String(format: "%.0f GB", localGB))
                                stat("可回收", String(format: "%.1f GB", s.disk.reclaimableGB))
                                stat("待处理", "\(s.issues.count) 条")
                                Spacer()
                            }
                            if let first = s.issues.first {
                                HStack(spacing: 6) {
                                    Circle().fill(sevColor(first.severity)).frame(width: 6, height: 6)
                                    Text(first.title).font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Spacer()
                                }
                            } else {
                                Text(s.installed.isEmpty
                                     ? "还没有装模型。到「模型推荐」点拉取，或到「导入 GGUF」加载本地文件。"
                                     : "每个模型的数据层都能对上，没有无主数据块。")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            HStack(spacing: 8) {
                                Button("去模型管理") { s.tab = .installed }
                                    .buttonStyle(.bordered).controlSize(.small)
                                Button("重新体检") { s.scanDisk() }
                                    .buttonStyle(.bordered).controlSize(.small)
                                Spacer()
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionHead(title: "判定依据", sub: "这份结论是怎么算出来的")
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            bullet("可用内存怎么算", "GPU 和 CPU 共用一块内存，所以没有独立显存。可用上限取 Metal 建议工作集与物理内存 80% 中的较小值，这台机器是 \(String(format: "%.1f", s.hw.metalWorkingSetGB)) GB 与 \(String(format: "%.1f", s.budgetGB)) GB。")
                            bullet("速度怎么估", "每生成一个 token 都要把用到的权重从内存读一遍，速度约等于带宽除以每 token 字节数。MoE 只读激活的专家，因此比同体积 dense 模型快很多。")
                            bullet("为什么有的模型不推荐", "容量够但估算速度低于 8 tok/s 的标「偏慢」；低于该用途速度下限的不进推荐。只按体积筛会推出一堆跑不动的模型。")
                            bullet("估算与实测", "速度先按带宽推算。跑过实测后以实测值为准，界面用不同颜色区分两者。")
                        }
                    }
                    Button {
                        s.exportReport()
                    } label: {
                        Label("导出体检报告（markdown）", systemImage: "square.and.arrow.up")
                            .font(.system(size: 11.5))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .onAppear {
            if s.bandwidth == nil { s.measureBandwidth() }
            if s.installed.isEmpty { s.refreshInstalled() }
            if s.disk.root.isEmpty { s.scanDisk() }
        }
    }

    var localGB: Double {
        s.installed.filter { !s.isCloud($0) }.reduce(0) { $0 + $1.sizeGB }
    }

    func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.system(size: 10.5)).foregroundStyle(.secondary)
            Text(v).font(.system(size: 15, weight: .semibold, design: .rounded))
        }
    }

    func sevColor(_ s: HealthIssue.Severity) -> Color {
        switch s {
        case .critical: return T.bad
        case .warning: return T.warn
        case .info: return Color.secondary
        }
    }

    func bullet(_ h: String, _ d: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(h).font(.system(size: 11.5, weight: .semibold))
            Text(d).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 硬件

struct HardwareView: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Card {
                VStack(alignment: .leading, spacing: 0) {
                    KeyRow(k: "芯片", v: s.hw.chip)
                    Divider().opacity(0.4)
                    KeyRow(k: "机型标识", v: s.hw.model)
                    Divider().opacity(0.4)
                    KeyRow(k: "系统", v: s.hw.osVersion)
                    Divider().opacity(0.4)
                    KeyRow(k: "CPU 核心", v: "\(s.hw.totalCores) 核（性能 \(s.hw.perfCores) / 能效 \(s.hw.effCores)）")
                    Divider().opacity(0.4)
                    KeyRow(k: "GPU", v: "\(s.hw.gpuName) · \(s.hw.gpuCores) 核")
                    Divider().opacity(0.4)
                    KeyRow(k: "统一内存", v: String(format: "%.1f GB", s.hw.ramGB))
                    Divider().opacity(0.4)
                    KeyRow(k: "Metal 建议工作集", v: String(format: "%.1f GB", s.hw.metalWorkingSetGB))
                    Divider().opacity(0.4)
                    KeyRow(k: "统一内存架构", v: s.hw.unified ? "是（CPU/GPU 共享）" : "否")
                    Divider().opacity(0.4)
                    KeyRow(k: "磁盘", v: String(format: "可用 %.0f GB / 共 %.0f GB", s.hw.diskFreeGB, s.hw.diskTotalGB))
                }
            }
            .frame(maxWidth: 460)

            VStack(alignment: .leading, spacing: 12) {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHead(title: "内存带宽实测", sub: "多核 memcpy 三轮回环，读+写计双倍流量")
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(s.bandwidth.map { String(format: "%.0f", $0) } ?? "—")
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .foregroundStyle(T.accent)
                            Text("GB/s").font(.system(size: 13)).foregroundStyle(.secondary)
                            Spacer()
                            Button(s.measuring ? "测量中…" : "重新测量") { s.measureBandwidth() }
                                .buttonStyle(.bordered).controlSize(.small)
                                .disabled(s.measuring)
                        }
                        Text("这是 CPU 侧可达带宽，通常低于厂商标称峰值；LLM decode 在 Metal 下约能吃掉其中的 60–75%。本工具用它乘 0.45 作为保守系数估算 tok/s。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHead(title: "怎么读这些数", sub: "")
                        Text("• 能装多大：权重 + KV cache + 1.6 GB 运行时 ≦ 预算\n• 跑多快：dense 模型基本与体积成反比；MoE 只看激活参数\n• 上下文越长，KV 吃掉的预算越多：64K 会让 30B 多花 3–8 GB")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
            }
        }
    }
}

// MARK: - 推荐

struct RecommendView: View {
    @EnvironmentObject var s: AppState

    let levels: [FitLevel] = [.plenty, .smooth, .ok, .tight, .tooHeavy]

    var body: some View {
        let ranked = s.ranked
        return VStack(alignment: .leading, spacing: 12) {
            Card {
                VStack(alignment: .leading, spacing: 9) {
                    SectionHead(title: "按用途自动匹配", sub: "选场景直接给结论；候选池按用途收窄，再按「规模 × 速度达标」打分")
                    HStack(spacing: 7) {
                        ForEach(Purpose.allCases) { p in
                            filterChip(p.rawValue, s.purpose == p) { s.purpose = p }
                        }
                        Spacer()
                    }
                    if let pair = s.match(s.purpose) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(pair.0.model.name)
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(T.accent)
                            Badge(text: pair.0.level.label, color: fitColor(pair.0.level))
                            Spacer()
                            if let tag = pair.0.model.tag {
                                PullButton(tag: tag)
                            } else if pair.0.model.cat == .image {
                                ImageBackendButton()
                            } else {
                                Button("HF 搜索") { s.openHF(pair.0.model.name) }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                        Text(pair.1).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        let alts = altLine(s.purpose)
                        if !alts.isEmpty {
                            Text(alts).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("该用途下没有能在 \(String(format: "%.0f", s.budgetGB)) GB 预算内跑起来的模型，建议放宽上下文或降低量化。")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 8) {
                filterChip("全部", s.category == nil) { s.category = nil }
                ForEach(ModelCategory.allCases) { c in
                    filterChip(c.rawValue, s.category == c) { s.category = c }
                }
                Spacer()
                Text("上下文").font(.system(size: 11.5)).foregroundStyle(.secondary)
                Picker("", selection: $s.contextTokens) {
                    ForEach(s.ctxOptions, id: \.self) { v in
                        Text("\(v / 1024)K").tag(v)
                    }
                }
                .labelsHidden()
                .frame(width: 92)
                .controlSize(.small)
            }

            HStack(spacing: 6) {
                Text("需求 = 权重 + KV + 1.6 GB 运行时；判定阈值基于 \(String(format: "%.0f", s.budgetGB)) GB 预算")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
                Text("\(ranked.count) 个候选").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }

            // 档位分布：一眼看出这台机器是在"随便挑"还是"只能挑几个"
            HStack(spacing: 14) {
                ForEach(levels, id: \.label) { l in
                    let n = ranked.filter { $0.level == l }.count
                    HStack(spacing: 5) {
                        Circle().fill(fitColor(l)).frame(width: 6, height: 6)
                        Text(l.label).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        Text("\(n)").font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(n == 0 ? Color.secondary : .primary)
                    }
                }
                Spacer()
            }

            if s.category == nil {
                ForEach(ModelCategory.allCases) { c in
                    let rows = ranked.filter { $0.model.cat == c }
                    if !rows.isEmpty {
                        HStack(spacing: 8) {
                            Text(c.rawValue).font(.system(size: 12, weight: .semibold))
                            Text("\(rows.count)").font(.system(size: 10.5, design: .rounded))
                                .foregroundStyle(.secondary)
                            Rectangle().fill(T.line).frame(height: 0.7)
                        }
                        .padding(.top, 4)
                        ForEach(rows) { a in
                            ModelRow(advice: a, compact: true)
                        }
                    }
                }
            } else {
                ForEach(ranked) { a in
                    ModelRow(advice: a, compact: true)
                }
            }
        }
    }

    func altLine(_ p: Purpose) -> String {
        let alts = Array(s.topMatches(p, limit: 3).dropFirst())
        guard !alts.isEmpty else { return "" }
        return "备选：" + alts.map {
            "\($0.model.name)（\(String(format: "%.0f", $0.estTokS)) tok/s）"
        }.joined(separator: " · ")
    }

    func filterChip(_ t: String, _ on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(t).font(.system(size: 11.5, weight: on ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 4.5)
                .background(Capsule().fill(on ? T.accent.opacity(0.18) : Color.primary.opacity(0.05)))
                .foregroundStyle(on ? T.accent : Color.primary.opacity(0.75))
                .overlay(Capsule().strokeBorder(on ? T.accent.opacity(0.35) : T.line, lineWidth: 0.6))
        }
        .buttonStyle(.plain)
    }
}

struct ModelRow: View {
    @EnvironmentObject var s: AppState
    let advice: Advice
    var compact: Bool

    var body: some View {
        let a = advice
        Card(pad: 11) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(a.model.name).font(.system(size: 12.5, weight: .semibold))
                        if a.model.activeB < a.model.paramsB {
                            Text("MoE").font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(T.accent.opacity(0.15)).foregroundStyle(T.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        Badge(text: a.level.label, color: fitColor(a.level))
                        if a.model.cat.chattable && a.level != .tooHeavy && a.estTokS < 8 {
                            Badge(text: "偏慢", color: T.warn)
                        }
                        if !a.model.cat.chattable {
                            Badge(text: a.model.cat.rawValue, color: T.accent)
                        }
                    }
                    Text("\(String(format: "%.1f", a.model.paramsB))B\(a.model.activeB < a.model.paramsB ? " / 激活 \(String(format: "%.1f", a.model.activeB))B" : "") · Q4 \(String(format: "%.1f", a.model.q4GB)) GB · \(a.model.note)")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .lineLimit(compact ? 1 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)

                if !compact {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(String(format: "%.1f GB", a.needGB))
                            .font(.system(size: 11.5, weight: .medium))
                        Text(String(format: "占预算 %.0f%%", a.ratio * 100))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .trailing, spacing: 3) {
                    if a.model.cat.chattable {
                        Text(String(format: "%.0f", a.estTokS))
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(a.estTokS > 25 ? T.good : (a.estTokS > 8 ? .primary : T.warn))
                        Text(s.benchmarks[a.model.name] != nil ? "实测 tok/s" : "估算 tok/s")
                            .font(.system(size: 9.5)).foregroundStyle(.secondary)
                    } else {
                        // 出图、转写、重排的"每秒 token"没有意义，不要编一个数出来
                        Text("—").font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                        Text("非对话模型").font(.system(size: 9.5)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 62, alignment: .trailing)

                if compact {
                    bar(a.ratio)
                        .frame(width: 74)
                }

                if let tag = a.model.tag {
                    PullButton(tag: tag)
                } else if a.model.cat == .image {
                    ImageBackendButton()
                } else {
                    Button("HF 搜索") { s.openHF(a.model.name) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }

    func bar(_ r: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(fitColor(advice.level).opacity(0.85))
                    .frame(width: max(3, geo.size.width * min(1.0, r)))
            }
        }
        .frame(height: 5)
    }
}


// MARK: - 任务匹配

struct CapBar: View {
    let label: String
    let value: Double
    var body: some View {
        HStack(spacing: 7) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(T.accent.opacity(0.85))
                        .frame(width: max(3, geo.size.width * min(1.0, value / 5.0)))
                }
            }
            .frame(height: 4)
            Text(String(format: "%.1f", value)).font(.system(size: 9.5, design: .rounded))
                .foregroundStyle(.secondary).frame(width: 20, alignment: .trailing)
        }
    }
}

struct TaskView: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        let b = s.blend
        let (list, rep) = s.taskMatchesWithReport(b, limit: 4)
        return VStack(alignment: .leading, spacing: 12) {
            Card {
                VStack(alignment: .leading, spacing: 9) {
                    SectionHead(title: "你是谁 · 你要做什么",
                                sub: "角色决定任务清单；任务可多选——门槛取最严，权重取均值")
                    HStack(spacing: 7) {
                        ForEach(WorkRole.allCases) { r in
                            chip(r.rawValue, s.role == r) { s.pickRole(r) }
                        }
                        Spacer()
                    }
                    HStack(spacing: 7) {
                        ForEach(s.role.tasks) { t in
                            chipMulti(t.rawValue, s.tasks.contains(t)) { s.toggleTask(t) }
                        }
                        Spacer()
                    }

                    // 合并后的门槛：多选时要说清"这个数是哪个任务定的"，否则用户不知道为什么变严了
                    HStack(spacing: 6) {
                        gatePill("上下文 ≥ \(b.minContext / 1024)K",
                                 tip: "来自「\(b.contextSource?.rawValue ?? "—")」：组合里要求最高的那个")
                        gatePill("速度 ≥ \(Int(b.minTokS)) tok/s",
                                 tip: "来自「\(b.speedSource?.rawValue ?? "—")」：组合里要求最高的那个")
                        if b.chineseHeavy {
                            gatePill("中文 ≥ 4.0",
                                     tip: "所选任务里有以中文产出为主的，中文语感低于 4.0 一律排除")
                        }
                        if b.needsVision {
                            gatePill("须支持看图", tip: "所选任务里有图表/截图理解，纯文本模型直接排除")
                        }
                        Spacer()
                        Text("已选 \(s.pickedTasks.count) 个")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        if s.pickedTasks.count > 1 {
                            Button("重置") { s.tasks = [s.role.tasks[0]] }
                                .buttonStyle(.bordered).controlSize(.small)
                                .help("回到该角色的第一个任务")
                        }
                    }

                    let dims = b.topDimensions(3)
                    Text("权重前 3：" + dims.map { d in
                        "\(d.0) \(String(format: "%.2f", d.1))"
                    }.joined(separator: " · "))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)

                    ForEach(Array(s.pickedTasks.prefix(3))) { t in
                        Text("· \(t.rawValue)：\(t.rationale)")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if s.pickedTasks.count > 3 {
                        Text("· 另 \(s.pickedTasks.count - 3) 个任务已计入权重与门槛")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
            }

            if let best = list.first {
                let cap = CapabilityModel.of(best.model)
                Card {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(best.model.name)
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundStyle(T.accent)
                            Badge(text: best.level.label, color: fitColor(best.level))
                            Badge(text: "能力 \(String(format: "%.2f", s.capabilityScore(best.model, b)))/5")
                            Spacer()
                            if let tag = best.model.tag {
                                PullButton(tag: tag, prominent: true)
                                Button("复制命令") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString("ollama pull \(tag)", forType: .string)
                                    s.toast = "已复制：ollama pull \(tag)"
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                            } else if best.model.cat == .image {
                                ImageBackendButton()
                            } else {
                                Button("HF 搜索") { s.openHF(best.model.name) }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                        VStack(spacing: 5) {
                            CapBar(label: "中文", value: cap.zh)
                            CapBar(label: "写作", value: cap.writing)
                            CapBar(label: "代码", value: cap.code)
                            CapBar(label: "数理", value: cap.math)
                            CapBar(label: "指令", value: cap.follow)
                            if cap.vision > 1.5 { CapBar(label: "视觉", value: cap.vision) }
                        }
                        Text(s.taskReason(b, best))
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Divider().opacity(0.4)
                        Text("筛选过程：" + rep.accounting)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                        ForEach(rep.warnings, id: \.self) { w in
                            Text("⚠ " + w)
                                .font(.system(size: 10.5)).foregroundStyle(T.warn)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else {
                Card {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("这个组合在当前预算与上下文要求下没有合适模型。")
                            .font(.system(size: 11.5, weight: .medium))
                        Text("筛选过程：" + rep.accounting)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text("可减少同时选中的任务（门槛会随之放宽）、降低上下文要求，或换量化更小的版本。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            let alts = Array(list.dropFirst())
            if !alts.isEmpty {
                SectionHead(title: "备选", sub: "同一套硬门槛之内，按综合分排；综合分 = 能力 × 家族修正 × 速度余量")
                ForEach(alts) { a in
                    Card(pad: 10) {
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.model.name).font(.system(size: 12, weight: .medium))
                                Text(a.model.note).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text("综合 \(String(format: "%.2f", s.taskScore(a.model, b)))")
                                .font(.system(size: 11)).monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .trailing)
                                .help("能力分乘上家族修正与速度余量，备选就是按这个数排的")
                            Text(String(format: "%.0f tok/s", a.estTokS))
                                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                                .foregroundStyle(a.estTokS > 20 ? T.good : .primary)
                                .frame(width: 70, alignment: .trailing)
                            Text(String(format: "%.1f GB", a.needGB))
                                .font(.system(size: 11)).monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 60, alignment: .trailing)
                            Badge(text: a.level.label, color: fitColor(a.level))
                                .frame(width: 74, alignment: .trailing)
                                .padding(.leading, 6)
                        }
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 5) {
                    Text("怎么读这个结论").font(.system(size: 11.5, weight: .medium))
                    Text("筛选顺序是容量、上下文、速度、中文语感。多选任务时，上下文取所有选中任务里要求最高的，速度取最高要求。通过筛选取后再按七维加权能力排序，权重由任务决定，所以同一个模型在「论文写作」和「代码实现」下排名不同。\n\n权重先按任务归一化到总和 1 再取平均。不归一化的话，原始权重和不同的任务会被动加码。门槛取最严而不是取平均，否则「写论文 + 看图表」这种组合会被一个两样都不行的模型拿下。\n\n能力分是按模型家族和规模推的先验值，不是公开榜单分数。排序用的是综合分：能力分乘上家族修正与速度余量，所以备选行的综合分可能比首选低一点、但速度更快。跑过实测后，速度以实测为准。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    func chip(_ t: String, _ on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(t).font(.system(size: 11.5, weight: on ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 4.5)
                .background(Capsule().fill(on ? T.accent.opacity(0.18) : Color.primary.opacity(0.05)))
                .foregroundStyle(on ? T.accent : Color.primary.opacity(0.75))
                .overlay(Capsule().strokeBorder(on ? T.accent.opacity(0.35) : T.line, lineWidth: 0.6))
        }
        .buttonStyle(.plain)
    }

    /// 多选芯片：选中态带一个对勾，让"能多选"这件事一眼可见
    func chipMulti(_ t: String, _ on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 4) {
                if on {
                    Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold))
                }
                Text(t).font(.system(size: 11.5, weight: on ? .semibold : .regular))
            }
            .padding(.horizontal, 10).padding(.vertical, 4.5)
            .background(Capsule().fill(on ? T.accent.opacity(0.18) : Color.primary.opacity(0.05)))
            .foregroundStyle(on ? T.accent : Color.primary.opacity(0.75))
            .overlay(Capsule().strokeBorder(on ? T.accent.opacity(0.35) : T.line, lineWidth: 0.6))
        }
        .buttonStyle(.plain)
        .help(on ? "再点一次取消（至少保留一个任务）" : "点一下加入组合")
    }

    func gatePill(_ text: String, tip: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
            .overlay(Capsule().strokeBorder(T.line, lineWidth: 0.6))
            .foregroundStyle(.secondary)
            .help(tip)
    }
}

// MARK: - 已装

struct InstalledView: View {
    @EnvironmentObject var s: AppState

    var cloudCount: Int { s.installed.filter { s.isCloud($0) }.count }
    var localGB: Double { s.installed.filter { !s.isCloud($0) }.reduce(0) { $0 + $1.sizeGB } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                MetricCard(title: "已装模型", value: "\(s.installed.count) 个",
                           sub: "本地 \(s.installed.filter { !s.isCloud($0) }.count) 个"
                                + (cloudCount > 0 ? " · 云端 \(cloudCount) 个" : ""),
                           tint: .primary)
                MetricCard(title: "占用磁盘", value: String(format: "%.0f GB", localGB),
                           sub: String(format: "只算本地权重；仓库连同清单共 %.0f GB", s.disk.modelTotalGB),
                           tint: .primary)
                MetricCard(title: "可回收", value: String(format: "%.1f GB", s.disk.reclaimableGB),
                           sub: "无主数据块，未被任何模型引用",
                           tint: s.disk.reclaimableGB > 0.05 ? T.warn : .secondary)
                MetricCard(title: "待处理", value: "\(s.issues.filter { $0.severity != .info }.count) 条",
                           sub: s.auditing ? "体检中…" : (s.disk.scannedAt == nil ? "还没体检" : "体检已完成"),
                           tint: s.issues.contains { $0.severity == .critical } ? T.bad
                               : (s.issues.contains { $0.severity == .warning } ? T.warn : T.good))
            }

            // 体检：读的是 ollama 的 manifests 与 blobs，不动任何文件
            Card {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        SectionHead(title: "体检", sub: "比对 manifest 声明的层与 blobs 实际存在的块")
                        Spacer()
                        Button(s.auditing ? "扫描中…" : "重新体检") { s.scanDisk() }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(s.auditing)
                    }
                    if s.disk.scannedAt == nil && s.issues.isEmpty {
                        Text("还没扫过。点「重新体检」检查模型是否完整、有没有白占空间的文件。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else if s.issues.isEmpty {
                        Text("没有发现问题：\(s.disk.manifests.count) 个模型的每个数据层都能对上。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        ForEach(s.issues) { i in
                            HStack(alignment: .top, spacing: 8) {
                                Circle().fill(sevColor(i.severity)).frame(width: 6, height: 6)
                                    .padding(.top, 5)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(i.title).font(.system(size: 11.5, weight: .medium))
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(i.detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 8)
                                if let m = i.model, s.installed.contains(where: { $0.name == m }) {
                                    Button("删除") {
                                        s.requestDelete(s.installed.filter { $0.name == m })
                                    }
                                    .buttonStyle(.bordered).controlSize(.small)
                                    .tint(T.bad)
                                }
                            }
                        }
                    }
                    if s.disk.rootExists {
                        Text("仓库路径：\(s.disk.root)")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                }
            }

            // 模型清单
            HStack(spacing: 8) {
                SectionHead(title: "模型清单", sub: "占预算按权重体积 ÷ 本机预算估，不含 KV 与运行时")
                Spacer()
                SearchBox(placeholder: "搜索模型名", text: $s.searchModel)
                Picker("", selection: $s.sortBy) {
                    ForEach(AppState.ModelSort.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .labelsHidden().frame(width: 96).controlSize(.small)
                Button(s.picked.count == s.visibleModels.count && !s.visibleModels.isEmpty ? "取消全选" : "全选") {
                    if s.picked.count == s.visibleModels.count { s.picked.removeAll() }
                    else { s.picked = Set(s.visibleModels.map { $0.id }) }
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(s.visibleModels.isEmpty)
                Button("刷新") { s.refreshInstalled(); s.scanDisk() }
                    .buttonStyle(.bordered).controlSize(.small)
            }

            if !s.picked.isEmpty {
                HStack(spacing: 8) {
                    Button {
                        s.requestDelete(s.pickedModels)
                    } label: {
                        Text(String(format: "删除所选 %d 个（%.1f GB）", s.picked.count, s.pickedGB))
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered).controlSize(.small).tint(T.bad)
                    Text("已选 \(s.picked.count) 个").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    Spacer()
                    Button("取消选择") { s.picked.removeAll() }
                        .buttonStyle(.plain).controlSize(.small)
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }

            if s.visibleModels.isEmpty {
                Card {
                    Text(s.installed.isEmpty
                         ? "还没有下载模型。可以到「模型推荐」里点拉取，或到「导入 GGUF」加载本地文件。"
                         : "没有匹配的模型。")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            } else {
                ForEach(s.visibleModels) { m in
                    modelRow(m)
                }
            }

            SectionHead(title: "推理引擎", sub: "检测到的客户端，按钮打开应用或安装页")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 10)], spacing: 10) {
                ForEach(s.engines) { e in
                    Card(pad: 11) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Text(e.name).font(.system(size: 12, weight: .semibold))
                                Badge(text: e.ready ? e.version : "未安装", color: e.ready ? T.good : T.warn)
                                Spacer()
                                Button(e.ready ? "打开" : "去安装") { s.openInstalledApp(e.name) }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                            Text(e.role).font(.system(size: 10)).foregroundStyle(.secondary)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if !s.log.isEmpty {
                SectionHead(title: "操作日志", sub: "")
                ScrollView {
                    Text(s.log)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(height: 140)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            }
        }
        .onAppear { if s.disk.scannedAt == nil { s.scanDisk() } }
        .alert("确认删除？", isPresented: $s.confirmDelete) {
            Button("取消", role: .cancel) { s.pendingDelete = [] }
            Button("删除", role: .destructive) { s.performDelete() }
        } message: {
            Text(deleteMessage)
        }
    }

    var deleteMessage: String {
        let list = s.pendingDelete
        let names = list.map { "· \($0.name)（\(String(format: "%.1f", $0.sizeGB)) GB）" }.joined(separator: "\n")
        let total = list.reduce(0.0) { $0 + $1.sizeGB }
        return """
        将从 Ollama 删除以下 \(list.count) 个模型，释放约 \(String(format: "%.1f", total)) GB：

        \(names)

        删除后需要重新下载才能恢复。GGUF 源文件不会被删除。
        """
    }

    func modelRow(_ m: InstalledModel) -> some View {
        let man = s.manifest(m.name)
        // manifest 里是 10^9 字节，预算按 GiB 算，先换成同一口径再求占比
        let gib = m.sizeGB * 1_000_000_000 / 1_073_741_824
        let ratio = s.budgetGB > 1 ? gib / s.budgetGB : 0
        return Card(pad: 10) {
            HStack(spacing: 10) {
                Button { s.togglePick(m) } label: {
                    Image(systemName: s.picked.contains(m.id) ? "checkmark.square.fill" : "square")
                        .font(.system(size: 13))
                        .foregroundStyle(s.picked.contains(m.id) ? T.accent : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("勾选后可批量删除")

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(m.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        if let man {
                            if man.remote { Badge(text: "云端", color: T.accent) }
                            if man.capabilities.contains("vision") { Badge(text: "视觉", color: T.good) }
                            if man.capabilities.contains("tools") { Badge(text: "工具", color: .secondary) }
                            if man.capabilities.contains("thinking") { Badge(text: "思考", color: .secondary) }
                            if man.capabilities.contains("embedding") { Badge(text: "嵌入", color: .secondary) }
                        }
                    }
                    Text(subtitle(m, man))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)

                Text(man?.remote == true ? "云端" : String(format: "%.1f GB", m.sizeGB))
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .frame(width: 62, alignment: .trailing)
                Text(ratio > 0 ? String(format: "%.0f%%", ratio * 100) : "—")
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(ratio > 0.92 ? T.bad : (ratio > 0.72 ? T.warn : .secondary))
                    .frame(width: 46, alignment: .trailing)
                    .help("占本机预算的比例")

                Button(s.benchRunning == m.name ? "运行中…" : "实测") {
                    s.tab = .bench
                    s.benchmark(model: m.name)
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(s.benchRunning != nil || m.engine != "Ollama")

                Button("定位") { s.revealModel(m) }
                    .buttonStyle(.bordered).controlSize(.small)

                Button("删除") { s.requestDelete([m]) }
                    .buttonStyle(.bordered).controlSize(.small).tint(T.bad)
                    .disabled(!m.deletable)
                    .help(m.deletable ? "从 Ollama 删除这个模型" : "LM Studio 目录不归本应用管，请用它的界面删")
            }
        }
    }

    func subtitle(_ m: InstalledModel, _ man: OllamaManifest?) -> String {
        var parts = [m.engine]
        if let q = man?.quant, q != "—" { parts.append(q) }
        else if m.quant != "—" { parts.append(m.quant) }
        if let p = man?.params, p != "—" { parts.append(p) }
        if let c = man?.contextLen, c > 0 { parts.append("\(c / 1024)K 上下文") }
        if m.modified != "—" { parts.append(m.modified) }
        return parts.joined(separator: " · ")
    }

    func sevColor(_ s: HealthIssue.Severity) -> Color {
        switch s {
        case .critical: return T.bad
        case .warning: return T.warn
        case .info: return Color.secondary
        }
    }
}

// MARK: - 在线模型

/// 在应用内搜索 HuggingFace 的 GGUF 模型。与内置目录互补：
/// 内置 79 条是精心挑选的快照，这里提供清单之外、社区持续更新的模型入口。
struct OnlineModelsView: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHead(title: "搜索在线 GGUF 模型",
                                sub: "清单外的模型也能找。HuggingFace + 魔搭双源，结果按下载量排序。")
                    HStack(spacing: 8) {
                        TextField("搜模型名，如 qwen / llama / mistral…", text: $s.hfQuery)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { s.searchHF() }
                        Button("搜索") { s.searchHF() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .disabled(s.hfSearching)
                        Button("热门 GGUF") { s.hfQuery = ""; s.searchHF() }
                            .buttonStyle(.bordered).controlSize(.small)
                        Spacer()
                    }
                    // 双源切换
                    HStack(spacing: 8) {
                        sourceChip("HuggingFace", 0, s.hfResults.count)
                        sourceChip("魔搭 ModelScope", 1, s.msResults.count)
                        Spacer()
                    }
                    if s.hfSearching {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("正在搜索 HuggingFace 与魔搭…").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                    }
                    if let err = s.hfError {
                        Text(err).font(.system(size: 11.5)).foregroundStyle(T.bad)
                    }
                    Text("模型来自社区仓库，license 各不相同；下载后到「导入 GGUF」注册即可使用，无模型白名单。")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }

            if s.searchSource == 0 {
                if !s.hfResults.isEmpty {
                    SectionHead(title: "HuggingFace（\(s.hfResults.count) 个）",
                                sub: "按下载量排序 · 点「下载」走 huggingface-cli，或「详情」手动下")
                    ForEach(s.hfResults) { m in HFRow(model: m) }
                } else if s.hfSearched && !s.hfSearching {
                    emptyCard()
                }
            } else {
                if !s.msResults.isEmpty {
                    SectionHead(title: "魔搭（\(s.msResults.count) 个）",
                                sub: "按下载量排序 · 点「详情」到魔搭页面下载")
                    ForEach(s.msResults) { m in MSRow(model: m) }
                } else if s.hfSearched && !s.hfSearching {
                    emptyCard()
                }
            }
        }
    }

    func sourceChip(_ label: String, _ idx: Int, _ count: Int) -> some View {
        Button { s.searchSource = idx } label: {
            HStack(spacing: 5) {
                Text(label).font(.system(size: 11.5, weight: s.searchSource == idx ? .semibold : .regular))
                Text("\(count)").font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 4.5)
            .background(Capsule().fill(s.searchSource == idx ? T.accent.opacity(0.18) : Color.primary.opacity(0.05)))
            .foregroundStyle(s.searchSource == idx ? T.accent : Color.primary.opacity(0.75))
            .overlay(Capsule().strokeBorder(s.searchSource == idx ? T.accent.opacity(0.35) : T.line, lineWidth: 0.6))
        }
        .buttonStyle(.plain)
    }

    func emptyCard() -> some View {
        Card {
            Text("没有结果。换个关键词，或点「热门 GGUF」看当前社区最火的模型。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

struct HFRow: View {
    @EnvironmentObject var s: AppState
    let model: HFModel

    var body: some View {
        Card(pad: 11) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(model.modelId)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                        Badge(text: model.license, color: T.accent)
                        if model.gated {
                            Badge(text: "需授权", color: T.warn)
                        }
                    }
                    HStack(spacing: 12) {
                        Label("\(model.downloads) 下载", systemImage: "arrow.down.circle")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        Label("\(model.likes) 赞", systemImage: "heart")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Button("下载") { s.downloadHF(model.modelId) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(s.busy != nil)
                    .help("huggingface-cli download \(model.modelId) --include *.gguf")
                Button("详情") { s.openHFModel(model.modelId) }
                    .buttonStyle(.plain).controlSize(.small)
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
    }
}

struct MSRow: View {
    @EnvironmentObject var s: AppState
    let model: MSModel

    var body: some View {
        Card(pad: 11) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("\(model.path)/\(model.name)")
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                        Badge(text: model.license, color: T.accent)
                    }
                    Label("\(model.downloads) 下载", systemImage: "arrow.down.circle")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("详情") {
                    if let u = model.pageURL { NSWorkspace.shared.open(u) }
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
        }
    }
}

// MARK: - 导入 GGUF

/// 拖放接收。离屏渲染时 SwiftUI 的拖放目标整块被画成黄色占位，
/// 截图里像是页面坏了，所以截图模式直接不挂这个 modifier。
struct DropGGUF: ViewModifier {
    let enabled: Bool
    @Binding var targeted: Bool
    let onPaths: ([String]) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                var paths: [String] = []
                let g = DispatchGroup()
                for p in providers {
                    g.enter()
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let u = url { paths.append(u.path) }
                        g.leave()
                    }
                }
                g.notify(queue: .main) { onPaths(paths) }
                return true
            }
        } else {
            content
        }
    }
}

struct GGUFView: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        let total = s.imports.reduce(0.0) { $0 + $1.bundle.main.fileGB }
        return VStack(alignment: .leading, spacing: 12) {
            Card {
                HStack(spacing: 12) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(s.dragged ? T.accent : Color.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("把 .gguf 拖到这里")
                            .font(.system(size: 13, weight: .semibold))
                        Text("只选主模型即可。同目录的分片和 mmproj 投影器会自动配对。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        s.pickGGUF()
                    } label: {
                        Label("选择文件", systemImage: "plus").font(.system(size: 11.5))
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    Button("选择目录") { s.pickGGUFFolder() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.vertical, 12).padding(.horizontal, 4)
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                        .foregroundStyle(s.dragged ? T.accent : T.line)
                        .padding(-6)
                )
                .modifier(DropGGUF(enabled: !s.snapshot, targeted: $s.dragged) { paths in
                    s.loadGGUF(paths: paths)
                })
            }

            if !s.imports.isEmpty {
                HStack(spacing: 8) {
                    Text("队列 \(s.imports.count) 个模型 · 合计 \(String(format: "%.1f", total)) GB")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    if s.busy == nil {
                        Button("全部注册") { s.register([]) }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .disabled(!s.imports.contains { $0.status == .idle })
                    } else {
                        Text(s.busy ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Button("清空") { s.clearImports() }
                        .buttonStyle(.bordered).controlSize(.small)
                }

                ForEach(s.imports) { item in
                    BundleCard(item: item)
                }
            } else {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("什么情况下需要多个文件").font(.system(size: 11.5, weight: .medium))
                        Text("纯文本模型一个 GGUF 就够，分词器、词表、对话模板都写在文件里。")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        Text("视觉模型还需要同目录的 mmproj-*.gguf，否则只能当纯文本用。")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        Text("被切成多片的模型，所有分片放在同一目录即可，注册时指向第一片。")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        Text("向量模型（bge-m3 等）是独立模型，供知识库检索，不能当对话模型。")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
            }

            if !s.log.isEmpty {
                SectionHead(title: "注册输出", sub: "")
                ScrollView {
                    Text(s.log)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled).padding(10)
                }
                .frame(height: 120)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            }
        }
    }
}

struct BundleCard: View {
    @EnvironmentObject var s: AppState
    let item: ImportItem

    var body: some View {
        let b = item.bundle
        let m = b.main
        let isEmbed = m.arch.lowercased().contains("bert") || m.arch.lowercased().contains("embed")
        let blocked = AppState.blockReason(item, ollamaReady: s.ollamaPath != nil)
        let taken = s.nameTaken(item.name)

        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TextField("模型名", text: Binding(
                        get: { item.name },
                        set: { s.renameImport(path: item.id, to: $0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 240)
                    .disabled(item.status == .running)

                    if taken {
                        Badge(text: "同名已存在，注册会覆盖", color: T.warn)
                    }
                    if let p = OllamaName.problem(item.name) {
                        Text(p).font(.system(size: 10)).foregroundStyle(T.bad)
                    } else if !taken {
                        Text("ollama run \(item.name)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    statusBadge
                }

                HStack(spacing: 6) {
                    check(shardOK, "分片 \(b.shards.count)/\(max(1, m.splitCount))")
                    check(b.projector != nil, b.suspectVision ? "投影器" : "投影器")
                    check(m.hasChatTemplate, "对话模板")
                    check(m.quant != "未知" && !m.quant.isEmpty, m.quant)
                    check(!m.paramsEstimated, m.paramsEstimated ? "参数量(估)" : "参数量")
                    check(!isEmbed, isEmbed ? "向量模型" : "对话模型")
                    Spacer()
                }

                HStack(spacing: 20) {
                    metaKV("参数", m.paramsEstimated ? String(format: "≈%.1f B", m.paramsB) : String(format: "%.1f B", m.paramsB))
                    metaKV("体积", String(format: "%.1f GB", m.fileGB))
                    metaKV("原生上下文", m.contextLength > 0 ? "\(m.contextLength)" : "未知")
                    metaKV("层数", m.blockCount > 0 ? "\(m.blockCount)" : "—")
                    metaKV("每 1K KV", String(format: "%.3f GB", m.kv1k))
                    metaKV("架构", m.arch)
                }

                if let why = blocked {
                    Text(why).font(.system(size: 10.5)).foregroundStyle(T.bad)
                        .fixedSize(horizontal: false, vertical: true)
                } else if b.missingProjector {
                    Text("看着像视觉模型，但同目录没有 mmproj。注册后只能处理文本。")
                        .font(.system(size: 10.5)).foregroundStyle(T.warn)
                } else if isEmbed {
                    Text("向量模型：注册后用 /api/embed 调用，不参与对话。")
                        .font(.system(size: 10.5)).foregroundStyle(T.accent)
                }

                HStack(spacing: 8) {
                    Button(item.status == .running ? "注册中…" : "注册进 Ollama") {
                        s.register([item.id])
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(blocked != nil || item.status == .running || s.busy != nil)

                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.selectFile(m.path, inFileViewerRootedAtPath: "")
                    }
                    .buttonStyle(.bordered).controlSize(.small)

                    Button("移出队列") { s.removeImport(path: item.id) }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(item.status == .running)

                    Spacer()
                    Text(m.path).font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
        }
    }

    var shardOK: Bool { bundle.main.splitCount <= 1 || bundle.shards.count >= bundle.main.splitCount }
    var bundle: ModelBundle { item.bundle }

    @ViewBuilder var statusBadge: some View {
        switch item.status {
        case .idle:
            Badge(text: "待注册", color: .secondary)
        case .running:
            Badge(text: "注册中", color: T.accent)
        case .ok(let n):
            Badge(text: "已注册 · \(n)", color: T.good)
        case .failed(let why):
            Badge(text: why, color: T.bad)
        }
    }

    func check(_ ok: Bool, _ label: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(ok ? T.good : T.warn)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7).padding(.vertical, 2.5)
        .background(Capsule().fill(Color.primary.opacity(0.04)))
        .overlay(Capsule().strokeBorder(T.line, lineWidth: 0.5))
    }

    func metaKV(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.system(size: 9.5)).foregroundStyle(.secondary)
            Text(v).font(.system(size: 11.5, weight: .medium, design: .rounded))
        }
    }
}

// MARK: - 对话

struct ChatView: View {
    @EnvironmentObject var s: AppState
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Card(pad: 10) {
                HStack(spacing: 8) {
                    Picker("", selection: $s.chatModel) {
                        Text("选择模型").tag("")
                        ForEach(s.chatModels) { m in
                            Text(m.name).tag(m.name)
                        }
                    }
                    .labelsHidden().frame(width: 240).controlSize(.small)

                    Picker("", selection: $s.chatCtx) {
                        ForEach([4096, 8192, 16384, 32768], id: \.self) { v in
                            Text("\(v / 1024)K 上下文").tag(v)
                        }
                    }
                    .labelsHidden().frame(width: 120).controlSize(.small)

                    if let b = s.benchmarks[s.chatModel], b > 0 {
                        Text(String(format: "上次实测 %.1f tok/s", b))
                            .font(.system(size: 10.5)).foregroundStyle(T.good)
                    }
                    Spacer()
                    if s.chatBusy {
                        Button("停止") { s.stopChat() }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                    Button("清空") { s.clearChat() }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(s.chat.isEmpty)
                }
            }

            if s.chatModels.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("还没有可对话的模型").font(.system(size: 12, weight: .medium))
                        Text("到「模型推荐」拉一个，或到「导入 GGUF」把本地的 .gguf 注册进来。导入的模型同样出现在这里，不受内置清单限制。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if s.chat.isEmpty {
                Card { hint }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(s.chat) { m in
                                bubble(m).id(m.id)
                            }
                            if s.chatBusy && s.chat.last?.text.isEmpty == true {
                                Text("正在生成…").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                    .frame(height: 400)
                    .onChange(of: s.chat.count) { _, _ in
                        if let last = s.chat.last { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                    .onChange(of: s.chat.last?.text) { _, _ in
                        if let last = s.chat.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            if let e = s.chatError {
                Text(e).font(.system(size: 10.5)).foregroundStyle(T.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Card(pad: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    if !s.pendingImages.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(Array(s.pendingImages.enumerated()), id: \.offset) { _, b64 in
                                if let img = thumb(b64) {
                                    Image(nsImage: img).resizable().frame(width: 40, height: 40)
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                }
                            }
                            Text("\(s.pendingImages.count) 张待发送")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                            Button("清掉") { s.pendingImages.removeAll() }
                                .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(T.accent)
                        }
                    }
                    if s.snapshot {
                        // 离屏渲染画不了输入控件，换成等高的静态提示
                        HStack {
                            Text(s.chatInput.isEmpty ? "输入内容，⌘↩ 发送" : s.chatInput)
                                .font(.system(size: 12.5))
                                .foregroundStyle(s.chatInput.isEmpty ? Color.secondary : .primary)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                        .frame(height: 26, alignment: .top)
                    } else {
                        TextField("输入内容，⌘↩ 发送", text: $s.chatInput, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .lineLimit(1...4)
                            .focused($inputFocused)
                            .padding(.vertical, 4)
                    }
                    HStack(spacing: 8) {
                        Button {
                            s.attachImages()
                        } label: {
                            Label("图片", systemImage: "photo").font(.system(size: 11))
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .help("发给视觉模型；纯文本模型会忽略图片")

                        Spacer()
                        Text("本地推理，内容不出本机").font(.system(size: 10)).foregroundStyle(.secondary)
                        Button(s.chatBusy ? "生成中…" : "发送") { s.sendChat() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(s.chatBusy || s.chatModel.isEmpty
                                      || (s.chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                          && s.pendingImages.isEmpty))
                    }
                }
            }
        }
        .onAppear {
            if s.chatModel.isEmpty { s.chatModel = s.chatModels.first?.name ?? "" }
        }
    }

    var hint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("这里直接调用本机 Ollama 跑模型，请求不发到外部。")
                .font(.system(size: 11.5))
            Text("带图片提问需要视觉模型（模型行会标「视觉」）。导入的 GGUF 注册后也在这里。")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder func bubble(_ m: ChatMsg) -> some View {
        let mine = m.role == "user"
        HStack {
            if mine { Spacer(minLength: 80) }
            VStack(alignment: .leading, spacing: 5) {
                if !m.images.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(Array(m.images.enumerated()), id: \.offset) { _, b64 in
                            if let img = thumb(b64) {
                                Image(nsImage: img).resizable().frame(width: 64, height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }
                if !m.text.isEmpty {
                    Text(m.text)
                        .font(.system(size: 12.5))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(mine ? T.accent.opacity(0.16) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(T.line, lineWidth: 0.5)
            )
            if !mine { Spacer(minLength: 80) }
        }
    }

    func thumb(_ b64: String) -> NSImage? {
        guard let d = Data(base64Encoded: b64) else { return nil }
        return NSImage(data: d)
    }
}

// MARK: - 智能体

struct AgentView: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 输入区
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHead(title: "交给模型一件事",
                                sub: "它会自己拆步骤、调用工具、把结果拼成答复。工具在后台执行，每一步都记录在下面。")
                    HStack(spacing: 8) {
                        Picker("", selection: $s.agentModel) {
                            Text("选择模型").tag("")
                            ForEach(s.chatModels) { m in
                                Text(m.name).tag(m.name)
                            }
                        }
                        .labelsHidden().frame(width: 240).controlSize(.small)

                        Text("工作目录").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(s.snapshot ? "~" : s.agentCwd)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(width: 200, alignment: .leading)
                        Button("改目录") { s.pickAgentCwd() }
                            .buttonStyle(.bordered).controlSize(.small)
                        Spacer()
                    }

                    if s.snapshot {
                        HStack {
                            Text(s.agentInput.isEmpty ? "描述要完成的事，例如：在 ~/code 下找出所有用了 TODO 标记的文件" : s.agentInput)
                                .font(.system(size: 12.5))
                                .foregroundStyle(s.agentInput.isEmpty ? Color.secondary : .primary)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4).frame(height: 26, alignment: .top)
                    } else {
                        TextField("描述要完成的事，例如：在 ~/code 下找出所有用了 TODO 标记的文件", text: $s.agentInput, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .lineLimit(1...4)
                            .padding(.vertical, 4)
                    }

                    HStack(spacing: 8) {
                        if s.snapshot {
                            HStack(spacing: 6) {
                                Image(systemName: s.agentAllowWrite ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 12))
                                Text("允许写文件和执行命令").font(.system(size: 11))
                            }
                            .foregroundStyle(s.agentAllowWrite ? T.good : .secondary)
                        } else {
                            Toggle("允许写文件和执行命令", isOn: $s.agentAllowWrite)
                                .toggleStyle(.switch).controlSize(.small)
                                .font(.system(size: 11))
                        }
                        Spacer()
                        if s.agentBusy {
                            Button("停止") { s.stopAgent() }
                                .buttonStyle(.bordered).controlSize(.small).tint(T.bad)
                        }
                        Button(s.agentBusy ? "运行中…" : "开始") {
                            s.runAgent(task: s.agentInput)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(s.agentBusy || s.agentModel.isEmpty
                                  || s.agentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let e = s.agentError {
                        Text(e).font(.system(size: 11)).foregroundStyle(T.bad)
                    }
                    Text("开关关着时，模型要写文件或跑命令会先弹窗问你是否放行；纯读操作（读文件、列目录、搜索）不需要授权。")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // 步骤记录
            if s.agentSteps.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("还没有运行记录").font(.system(size: 12.5, weight: .medium))
                        Text("可以试：\n· 读 ~/Desktop 下的某个文档并总结\n· 在当前目录找带 TODO 的代码文件\n· 写一个 Python 脚本并跑一遍")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                SectionHead(title: "运行过程",
                            sub: "模型想什么、调了什么工具、工具回了什么，全在这里")
                ForEach(s.agentSteps) { step in
                    AgentStepRow(step: step)
                }
            }
        }
        .onAppear {
            if s.agentModel.isEmpty, let f = s.chatModels.first { s.agentModel = f.name }
        }
        .alert("允许这个操作吗？", isPresented: confirmBinding) {
            Button("允许", role: .none) { s.resolveConfirm(true) }
            Button("拒绝", role: .cancel) { s.resolveConfirm(false) }
        } message: {
            if let c = s.agentPendingConfirm {
                Text(describe(c))
            } else {
                Text("")
            }
        }
    }

    private var confirmBinding: Binding<Bool> {
        Binding(
            get: { s.agentPendingConfirm != nil },
            set: { if !$0 { s.resolveConfirm(false) } }
        )
    }

    private func describe(_ c: ToolCall) -> String {
        switch c.name {
        case "write_file":
            let p = c.arguments["path"] ?? "?"
            return "模型要写入文件：\(p)\n内容长度 \(c.arguments["content"]?.count ?? 0) 字符。"
        case "run_command":
            return "模型要执行命令：\(c.arguments["command"] ?? "?")\n工作目录：\(c.arguments["cwd"] ?? s.agentCwd)"
        default:
            return "模型要调用工具：\(c.name)"
        }
    }
}

struct AgentStepRow: View {
    let step: AgentStep

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 16, alignment: .center)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(step.title).font(.system(size: 11, weight: .semibold))
                    Badge(text: kindLabel, color: tint)
                }
                Text(step.detail)
                    .font(.system(size: step.kind == .tool || step.kind == .result ? 10.5 : 12))
                    .foregroundStyle(step.kind == .tool || step.kind == .result ? Color.secondary : .primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(T.line, lineWidth: 0.5))
    }

    var icon: String {
        switch step.kind {
        case .thought: return "brain"
        case .tool: return "wrench"
        case .result: return "doc.text"
        case .answer: return "checkmark.circle"
        }
    }
    var tint: Color {
        switch step.kind {
        case .thought: return T.accent
        case .tool: return Color(red: 0.42, green: 0.70, blue: 0.96)
        case .result: return .secondary
        case .answer: return T.good
        }
    }
    var kindLabel: String {
        switch step.kind {
        case .thought: return "思考"
        case .tool: return "工具"
        case .result: return "结果"
        case .answer: return "答复"
        }
    }
}

// MARK: - 实测

struct BenchView: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        let rows = s.benchRecords.values.sorted { $0.tps > $1.tps }
        let median = rows.isEmpty ? 0 : rows.sorted { $0.tps < $1.tps }[rows.count / 2].tps
        let gaps: [Double] = rows.compactMap { r in
            guard let m = s.catalogEntry(r.model) else { return nil }
            let e = s.estTokS(m)
            return e > 0 ? (r.tps - e) / e * 100 : nil
        }
        return VStack(alignment: .leading, spacing: 12) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHead(title: "让 Ollama 真跑一次",
                                sub: "读 eval_count / eval_duration，不经过任何估算公式")
                    HStack(spacing: 8) {
                        Picker("", selection: $s.pickedModel) {
                            Text("选择模型").tag("")
                            ForEach(s.installed.filter { $0.engine == "Ollama" }) { m in
                                Text(m.name).tag(m.name)
                            }
                        }
                        .labelsHidden().frame(width: 240).controlSize(.small)

                        Button(s.benchRunning == nil ? "实测这一个" : "运行中…") {
                            if !s.pickedModel.isEmpty { s.benchmark(model: s.pickedModel) }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(s.pickedModel.isEmpty || s.benchRunning != nil)

                        Button("全部已装跑一遍") { s.benchmarkAll() }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(s.benchRunning != nil || s.benchQueue != nil)

                        if let q = s.benchQueue {
                            Text("\(q.done)/\(q.total)").font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !rows.isEmpty {
                            Button("清空记录") {
                                for r in rows { s.clearBench(r.model) }
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                    if !s.benchMsg.isEmpty {
                        Text(s.benchMsg).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Text("第一次调用含模型加载时间，第二次起才是稳定速度。全部跑一遍是串行执行的——同时跑会让带宽互相争抢，测出来的数都偏低。")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                MetricCard(title: "已实测", value: "\(rows.count) 个",
                           sub: rows.isEmpty ? "还没跑过" : "占已装 Ollama 模型的一部分")
                MetricCard(title: "中位速度", value: rows.isEmpty ? "—" : String(format: "%.1f", median),
                           sub: "tok/s，去掉极值看中间那个",
                           tint: rows.isEmpty ? Color.secondary : T.good)
                MetricCard(title: "实测与估算的差",
                           value: gaps.isEmpty ? "—" : String(format: "%+.0f%%", gaps.sorted()[gaps.count / 2]),
                           sub: gaps.isEmpty ? "清单外的模型不给估算" : "取中位，负值表示估算偏乐观",
                           tint: (gaps.isEmpty ? Color.secondary : (gaps.sorted()[gaps.count / 2] < -10 ? T.warn : .primary)))
                MetricCard(title: "内存带宽", value: s.bandwidth.map { String(format: "%.0f", $0) } ?? "—",
                           sub: "GB/s，速度估算的输入")
            }

            if rows.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("还没有实测记录").font(.system(size: 12.5, weight: .medium))
                        Text("上面选一个模型跑一次即可。跑完之后，推荐页和对话页会用实测值替换估算值，并用颜色区分两者。")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                SectionHead(title: "本机实测记录",
                            sub: "同一模型再跑一次会覆盖旧值，两次差 5% 以上会标出来")
                Card(pad: 0) {
                    VStack(spacing: 0) {
                        HStack(spacing: 10) {
                            Text("模型").frame(maxWidth: .infinity, alignment: .leading)
                            Text("实测").frame(width: 62, alignment: .trailing)
                            Text("估算").frame(width: 54, alignment: .trailing)
                            Text("预填充").frame(width: 58, alignment: .trailing)
                            Text("时间").frame(width: 96, alignment: .trailing)
                            Color.clear.frame(width: 28)
                        }
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 6)

                        ForEach(rows) { r in
                            Divider().opacity(0.4)
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(r.model).font(.system(size: 12, weight: .medium))
                                    if !r.note.isEmpty {
                                        Text(r.note).font(.system(size: 10)).foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                Text(String(format: "%.1f", r.tps))
                                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                                    .foregroundStyle(T.good)
                                    .frame(width: 62, alignment: .trailing)

                                Text(estText(r))
                                    .font(.system(size: 11.5)).monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 54, alignment: .trailing)

                                Text(r.prefill > 0 ? String(format: "%.0f", r.prefill) : "—")
                                    .font(.system(size: 11.5)).monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 58, alignment: .trailing)

                                Text(stamp(r.at))
                                    .font(.system(size: 10.5)).monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 96, alignment: .trailing)

                                Button {
                                    s.clearBench(r.model)
                                } label: {
                                    Image(systemName: "xmark.circle").font(.system(size: 11))
                                }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .frame(width: 28)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                        }
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 7) {
                    SectionHead(title: "为什么实测常比估算低")
                    Bullet("估算只算了权重", "公式里的每 token 字节数按权重体积和激活比例算，KV cache 的读写、注意力计算、采样都没算进去。上下文越长，差距越大。")
                    Bullet("首次调用含加载", "从磁盘读几十 GB 权重进内存，这段时间也被算进第一次的耗时。第二次跑同一个模型才是稳定的。")
                    Bullet("机器不空闲", "后台在跑索引、Time Machine、浏览器，带宽会被分走。同一台机器上午和下午测同一个模型差 10% 很常见。")
                    Bullet("估算偏乐观的用处", "正因为估算偏乐观，才不能只靠它下结论。清单外的模型（自己转换的 GGUF）不给估算值，直接显示「—」。")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            if s.pickedModel.isEmpty, let f = s.installed.first(where: { $0.engine == "Ollama" }) {
                s.pickedModel = f.name
            }
        }
    }

    func estText(_ r: AppState.BenchRecord) -> String {
        guard let m = s.catalogEntry(r.model) else { return "—" }
        return String(format: "%.0f", s.estTokS(m))
    }

    func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "今天 HH:mm" : "MM-dd HH:mm"
        return f.string(from: d)
    }
}

