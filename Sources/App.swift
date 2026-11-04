import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

/// 一条对话消息。images 是 base64（不带 data: 前缀），Ollama 的 /api/chat 直接收这个格式。
struct ChatMsg: Identifiable, Equatable {
    let id = UUID()
    var role: String        // user / assistant / system
    var text: String
    var images: [String] = []
}

/// 一次导入的完整模型：主文件 + 可选投影器 + 其余分片
struct ModelBundle {
    var main: GGUFInfo
    var projector: GGUFInfo?
    var shards: [String] = []
    var suspectVision = false
    var missingProjector = false
    var onlyProjectorSelected = false
}

/// 导入队列里的一项。模型名可改，注册状态独立，便于批量导入时逐条看结果。
enum ImportStatus: Equatable {
    case idle
    case running
    case ok(String)       // 注册成功的模型名
    case failed(String)   // 可直接展示的原因
}

struct ImportItem: Identifiable {
    var id: String { bundle.main.path }
    var bundle: ModelBundle
    var name: String
    var status: ImportStatus = .idle
}

@MainActor
final class AppState: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "概览"
        case hardware = "硬件体检"
        case recommend = "模型推荐"
        case task = "任务匹配"
        case installed = "已装与引擎"
        case online = "在线模型"
        case importGGUF = "导入 GGUF"
        case bench = "实测基准"
        case chat = "对话"
        case agent = "智能体"
        var id: String { rawValue }
        /// 英文键，供 `MM_TAB=task` 这类自动化/截图脚本定位页签
        var key: String {
            switch self {
            case .overview: return "overview"
            case .hardware: return "hardware"
            case .recommend: return "recommend"
            case .task: return "task"
            case .installed: return "installed"
            case .online: return "online"
            case .importGGUF: return "import"
            case .bench: return "bench"
            case .chat: return "chat"
            case .agent: return "agent"
            }
        }
        var icon: String {
            switch self {
            case .overview: return "square.grid.2x2"
            case .hardware: return "cpu"
            case .recommend: return "sparkles"
            case .task: return "target"
            case .installed: return "internaldrive"
            case .online: return "globe"
            case .importGGUF: return "shippingbox"
            case .bench: return "speedometer"
            case .chat: return "bubble.left.and.bubble.right"
            case .agent: return "wrench.and.screwdriver"
            }
        }
    }

    @Published var tab: Tab = .overview
    @Published var hw = Hardware()
    @Published var bandwidth: Double?
    @Published var measuring = false
    @Published var contextTokens = 16384
    @Published var category: ModelCategory?
    @Published var installed: [InstalledModel] = []
    @Published var engines: [Engine] = []
    @Published var benchRecords: [String: BenchRecord] = [:] {
        didSet { saveBench() }
    }
    @Published var benchRunning: String?
    @Published var benchQueue: (done: Int, total: Int)?
    @Published var benchMsg = ""
    @Published var pickedModel = ""
    @Published var log = ""
    @Published var busy: String?

    // 模型拉取进度（ollama pull 实时解析）
    /// 正在拉取的模型 tag；nil 表示当前没有进行中的拉取
    @Published var pullTag: String?
    /// 当前层正在拉取：hash、百分比（0~1）、已下载/总大小、速度、剩余时间
    @Published var pullLayer: (hash: String, pct: Double, done: String, total: String, speed: String, eta: String)?
    /// 是否正在校验已有层（断点续传时 Ollama 会先 verify，无百分比）
    @Published var pullVerifying = false
    private var pullProc: Process?
    @Published var imports: [ImportItem] = []
    @Published var dragged = false
    @Published var toast: String?

    // 在线模型搜索（HuggingFace + ModelScope 魔搭 GGUF）
    @Published var hfQuery = ""
    @Published var hfResults: [HFModel] = []
    @Published var msResults: [MSModel] = []
    @Published var hfSearching = false
    @Published var hfError: String?
    @Published var hfSearched = false
    /// 搜索源：0 = HuggingFace，1 = 魔搭 ModelScope（国内默认）
    @Published var searchSource = 1

    // 魔搭应用内直下
    /// 当前正在浏览文件的仓库（org/name），非空时展示文件列表弹层
    @Published var msListing: MSListing?
    /// 仓库文件列表（.gguf / .mmproj）
    @Published var msFiles: [MSFile] = []
    @Published var msFilesLoading = false
    /// 正在下载的文件（含进度：已下载/总字节）
    @Published var msDownloading: (path: String, received: Int64, total: Int64)?
    @Published var msDownloaded: URL?

    // 模型仓库
    @Published var disk = DiskScan()
    @Published var issues: [HealthIssue] = []
    @Published var auditing = false
    @Published var picked = Set<String>()          // 已勾选的 InstalledModel.id
    @Published var pendingDelete: [InstalledModel] = []
    @Published var confirmDelete = false
    @Published var searchModel = ""
    @Published var sortBy: ModelSort = .size

    // 对话
    @Published var chat: [ChatMsg] = []
    @Published var chatModel = ""
    @Published var chatInput = ""
    @Published var chatBusy = false
    @Published var chatError: String?
    @Published var chatCtx = 8192
    @Published var pendingImages: [String] = []
    private var chatTask: Task<Void, Never>?

    // 智能体（工具调用）
    @Published var agentModel = ""
    @Published var agentInput = ""
    @Published var agentBusy = false
    @Published var agentError: String?
    @Published var agentSteps: [AgentStep] = []
    @Published var agentCwd = NSHomeDirectory()
    /// 是否允许写文件与执行命令。默认关，模型第一次想动手时弹确认。
    @Published var agentAllowWrite = false
    /// 需要用户确认的待执行工具（写文件/命令）
    @Published var agentPendingConfirm: ToolCall?
    @Published var agentConfirmChoice = false
    private var agentTask: Task<Void, Never>?

    let ctxOptions = [4096, 8192, 16384, 32768, 65536, 131072]

    /// 离屏截图模式。TextField 与拖放区在 ImageRenderer 里会被画成黄色占位块，
    /// 截图时换成等高的静态占位，保证文档里的图是页面真实长什么样。
    let snapshot: Bool

    init() {
        snapshot = ProcessInfo.processInfo.environment["MM_SNAPSHOT"] != nil
        // 自动化截图 / 回归用：MM_TAB=task 直接落在指定页签，不影响正常使用
        if let k = ProcessInfo.processInfo.environment["MM_TAB"],
           let t = Tab.allCases.first(where: { $0.key == k }) {
            tab = t
        }
        loadBench()
    }

    /// 实测记录只暴露成 [模型名: tok/s] 给推荐引擎，历史细节留在 benchRecords 里
    var benchmarks: [String: Double] { benchRecords.mapValues { $0.tps } }

    /// 云端模型没有本地权重，跑实测没有意义，也不占磁盘
    func isCloud(_ m: InstalledModel) -> Bool { manifest(m.name)?.remote ?? false }

    var ollamaPath: String? { engines.first(where: { $0.name == "Ollama" && $0.ready })?.path }

    /// 已就绪的文生图后端（ComfyUI 或 stable-diffusion.cpp），Ollama 跑不了图
    var imageBackends: [Engine] {
        engines.filter { ($0.name == "ComfyUI" || $0.name == "stable-diffusion.cpp") && $0.ready }
    }

    /// 文生图后端是否至少有一个可用
    var hasImageBackend: Bool { !imageBackends.isEmpty }

    /// 可用于权重的统一内存预算：取 Metal 建议工作集与 80% 物理内存的较小值
    var budgetGB: Double {
        let m = hw.metalWorkingSetGB > 0 ? hw.metalWorkingSetGB : hw.ramGB * 0.75
        return min(m, hw.ramGB * 0.80)
    }

    /// 推荐引擎（纯逻辑，见 Advisor.swift）
    var advisor: Advisor {
        Advisor(budgetGB: budgetGB,
                bandwidth: bandwidth ?? 0,
                contextTokens: contextTokens,
                benchmarks: benchmarks,
                ctxOptions: ctxOptions)
    }

    @Published var purpose: Purpose = .writing
    @Published var role: WorkRole = .researcher { didSet { saveSelection() } }
    /// 多选：场景通常不是一个 —— 写论文时同时在跑数据分析、还要看图表
    @Published var tasks: Set<WorkTask> = [.paper] { didSet { saveSelection() } }

    /// 按固定顺序展开（Set 无序，直接遍历会让芯片顺序在每次重绘时跳动）
    var pickedTasks: [WorkTask] { WorkTask.allCases.filter { tasks.contains($0) } }
    var blend: TaskBlend { TaskBlend(tasks: pickedTasks) }

    // MARK: - 选择持久化（下次打开还是上次那套）

    private enum Pref {
        static let role = "mm.role"
        static let tasks = "mm.tasks"
    }

    private func saveSelection() {
        let d = UserDefaults.standard
        d.set(role.rawValue, forKey: Pref.role)
        d.set(pickedTasks.map { $0.rawValue }.joined(separator: ","), forKey: Pref.tasks)
    }

    func restoreSelection() {
        let d = UserDefaults.standard
        // 先把两个值都读出来再赋值：role 的 didSet 会立刻回写一次，
        // 若边读边写，刚读到的 tasks 会被这次回写覆盖掉（曾因此丢过多选）。
        let savedRole = d.string(forKey: Pref.role)
        let savedTasks = d.string(forKey: Pref.tasks)

        let set = Set((savedTasks ?? "").split(separator: ",")
                        .compactMap { WorkTask(rawValue: String($0)) })
        if !set.isEmpty { tasks = set }
        if let r = savedRole, let rr = WorkRole(rawValue: r) { role = rr }
    }

    // MARK: - 实测记录持久化

    private static let benchKey = "mm.bench"

    private func saveBench() {
        guard let data = try? JSONEncoder().encode(Array(benchRecords.values)) else { return }
        UserDefaults.standard.set(data, forKey: Self.benchKey)
    }

    private func loadBench() {
        guard let data = UserDefaults.standard.data(forKey: Self.benchKey),
              let list = try? JSONDecoder().decode([BenchRecord].self, from: data) else { return }
        // 用合并而不是直接赋值：init 阶段 didSet 不会触发，但后续恢复时会
        benchRecords = Dictionary(uniqueKeysWithValues: list.map { ($0.model, $0) })
    }

    func need(_ m: LocalModel, ctx: Int? = nil) -> Double { advisor.need(m, ctx: ctx) }
    func level(_ m: LocalModel) -> FitLevel { advisor.level(m) }
    func ratio(_ m: LocalModel) -> Double { advisor.ratio(m) }
    func estTokS(_ m: LocalModel) -> Double { advisor.estTokS(m) }
    func maxContext(_ m: LocalModel) -> Int { advisor.maxContext(m) }
    func match(_ p: Purpose) -> (Advice, String)? { advisor.match(p) }
    func topMatches(_ p: Purpose, limit: Int = 3) -> [Advice] { advisor.topMatches(p, limit: limit) }

    var ranked: [Advice] { advisor.ranked(category: category) }
    func taskMatches(_ b: TaskBlend, limit: Int = 4) -> [Advice] { advisor.taskMatches(b, limit: limit) }
    func taskMatchesWithReport(_ b: TaskBlend, limit: Int = 4) -> ([Advice], GateReport) {
        advisor.taskMatchesWithReport(b, limit: limit)
    }
    func taskReason(_ b: TaskBlend, _ a: Advice) -> String { advisor.taskReason(b, a) }
    func capabilityScore(_ m: LocalModel, _ b: TaskBlend) -> Double { advisor.capabilityScore(m, b) }
    func taskScore(_ m: LocalModel, _ b: TaskBlend) -> Double { advisor.taskScore(m, b) }
    var sweetSpot: String { advisor.sweetSpot }
    var fitCount: Int { advisor.fitCount(Catalog.all) }

    // MARK: - 任务选择

    func toggleTask(_ t: WorkTask) {
        if tasks.contains(t) {
            // 至少保留一个：全空会让整个推荐页没有结论，比"选错"更糟
            guard tasks.count > 1 else {
                toast = "至少保留一个任务；想换就先点中意的那个，再取消这个"
                return
            }
            tasks.remove(t)
        } else {
            tasks.insert(t)
        }
    }

    func pickRole(_ r: WorkRole) {
        role = r
        // 角色切换：保留仍属于新角色的已选任务；一个都不剩就取该角色第一个
        let keep = tasks.intersection(Set(r.tasks))
        tasks = keep.isEmpty ? [r.tasks[0]] : keep
    }

    // MARK: - 加载

    func boot() {
        restoreSelection()
        engines = Runtime.detect()
        DispatchQueue.global(qos: .userInitiated).async {
            let h = Probe.probe()
            let b = Probe.measureBandwidth()
            let inst = Runtime.installed(ollamaPath: self.ollamaPathSnapshot())
            DispatchQueue.main.async {
                self.hw = h
                self.bandwidth = b > 1 ? b : nil
                self.installed = inst
            }
        }
    }

    private nonisolated func ollamaPathSnapshot() -> String? { Sh.find("ollama") }

    func measureBandwidth() {
        measuring = true
        DispatchQueue.global(qos: .userInitiated).async {
            let b = Probe.measureBandwidth()
            DispatchQueue.main.async {
                self.bandwidth = b > 1 ? b : nil
                self.measuring = false
            }
        }
    }

    func refreshInstalled() {
        let p = ollamaPath
        DispatchQueue.global(qos: .userInitiated).async {
            let list = Runtime.installed(ollamaPath: p)
            DispatchQueue.main.async { self.installed = list }
        }
    }

    // MARK: - 动作

    func runPull(_ tag: String) {
        guard let p = ollamaPath else { toast = "未检测到 Ollama"; return }
        guard pullProc == nil else { toast = "已有模型在拉取中，请先等它完成或取消"; return }
        busy = "拉取 \(tag)"
        log = ""
        pullTag = tag
        pullLayer = nil
        pullVerifying = false
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: p)
            proc.arguments = ["pull", tag]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            DispatchQueue.main.async { self.pullProc = proc }

            // 残留缓冲：ollama pull 的进度用 \r（回车）覆盖刷新、\n 才换行，
            // 所以 stdout 里大量内容是被 \r 黏在一起的"覆盖序列"。这里同时按 \r 和 \n
            // 切段，只把每段里的最新一条进度交给解析；段尾不完整则留在 rest 等下一块拼。
            var rest = ""
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
                let chunk = rest + s
                rest = ""
                // 用 \r 或 \n 作为段边界；覆盖动画里只有最后一个 \r 之后才是"当前"进度
                let segs = chunk.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
                // 若 chunk 不是以 \r/\n 结尾，最后一段不完整，留下次拼
                if !chunk.hasSuffix("\r") && !chunk.hasSuffix("\n") {
                    if let last = segs.last, !last.isEmpty { rest = last }
                }
                for seg in segs {
                    let line = seg.trimmingCharacters(in: .whitespaces)
                    guard !line.isEmpty else { continue }
                    // 只有"最新"的进度才有意义；但日志要留全。这里只解析最新一条，
                    // 靠 \r 覆盖的性质，同一 chunk 里最后一条就是当前进度。
                    DispatchQueue.main.async { self.consumePullLine(line) }
                }
            }
            try? proc.run()
            proc.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil
            let code = proc.terminationStatus
            DispatchQueue.main.async {
                self.pullProc = nil
                let ok = code == 0
                self.pullTag = nil
                self.pullLayer = nil
                self.pullVerifying = false
                self.busy = nil
                self.log += ok
                    ? "\n[完成] \(tag) 拉取成功\n"
                    : "\n[失败] \(tag) 退出码 \(code)。中断未完成的部分已保留，重新点「拉取」即可断点续传。\n"
                if ok {
                    // 自动装载：刷新已装列表后，直接落到对话页签并选中该模型
                    self.refreshInstalled()
                    self.toast = "\(tag) 已就绪，已为你切到「对话」可直接用"
                    // refreshInstalled 是异步的，稍等列表回来再切页签选中
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        guard let m = self.installed.first(where: { $0.name == tag }) else { return }
                        self.chatModel = m.name
                        self.tab = .chat
                    }
                }
            }
        }
    }

    /// 取消当前拉取。Ollama 会在当前层下完后退出，已下载层全部保留，下次拉取自动续传。
    func cancelPull() {
        guard let proc = pullProc else { return }
        proc.terminate()
        log += "\n[取消] 已请求中断，当前层完成后停止；已下载部分保留，可断点续传。\n"
    }

    /// 解析 ollama pull 的每一行输出，更新进度状态。
    /// 已知格式（Ollama 0.40.x）：
    ///   pulling c5396e06af29:  13% ▕██     ▏  52 MB/397 MB  17 MB/s  19s
    ///   pulling manifest
    ///   pulling 8934d96d3f08: 100% ▕█████▏ 397 MB
    ///   verifying sha256 digest
    ///   writing manifest
    ///   success
    private func consumePullLine(_ raw: String) {
        // 清掉 Ollama 的 ANSI 控制码（如 \u{1B}[?25l 隐藏光标），否则日志出现乱码
        var line = raw.trimmingCharacters(in: .whitespaces)
        if line.contains("\u{1B}") {
            line = line.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[a-zA-Z]", with: "",
                                             options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        guard !line.isEmpty else { return }

        if line.hasPrefix("pulling manifest") || line.hasPrefix("writing manifest")
            || line.hasPrefix("success") || line.hasPrefix("verifying")
            || line.hasPrefix("Error") || line.hasPrefix("error") {
            // 关键事件才进日志；进度条（pulling <hash>: …）是 \r 覆盖的动画，
            // 若每段都写日志会灌入几千条重复行，这里只留里程碑。
            self.log += line + "\n"
        }

        if line.hasPrefix("pulling manifest") || line.hasPrefix("writing manifest")
            || line.hasPrefix("success") {
            return
        }
        if line.hasPrefix("verifying") {
            self.pullVerifying = true
            return
        }

        // pulling <hash>: <pct>% ▕...▏ <done>/<total> <speed> <eta>
        if line.hasPrefix("pulling ") {
            let body = String(line.dropFirst("pulling ".count))
            // 层 hash 冒号后的部分
            let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return }
            let hash = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let rest = String(parts[1])

            // 百分比
            var pct = 0.0
            if let r = rest.range(of: #"\d{1,3}%"#, options: .regularExpression) {
                let s = String(rest[r])
                pct = Double(s.dropLast())! / 100.0
            }
            // 大小：done/total
            var done = "", total = ""
            if let r = rest.range(of: #"\d+(\.\d+)?\s*[KMGTP]?B\s*/\s*\d+(\.\d+)?\s*[KMGTP]?B"#, options: .regularExpression) {
                let pair = String(rest[r]).split(separator: "/")
                if pair.count == 2 {
                    done = pair[0].trimmingCharacters(in: .whitespaces)
                    total = pair[1].trimmingCharacters(in: .whitespaces)
                }
            }
            // 速度与剩余时间
            var speed = "", eta = ""
            if let r = rest.range(of: #"\d+(\.\d+)?\s*[KMGTP]?B/s"#, options: .regularExpression) {
                speed = String(rest[r])
            }
            if let r = rest.range(of: #"\d+[smh](?=\s|$)"#, options: .regularExpression) {
                eta = String(rest[r])
            }

            self.pullVerifying = false
            self.pullLayer = (hash: hash, pct: pct, done: done, total: total, speed: speed, eta: eta)
        }
    }

    func openHF(_ name: String) {
        let q = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        if let u = URL(string: "https://hf-mirror.com/models?search=\(q)%20GGUF") {
            NSWorkspace.shared.open(u)
        }
    }

    /// 在应用内搜索 GGUF 模型（HuggingFace + 魔搭双源，不跳浏览器）。
    /// 双源独立容错：一个源失败不拖垮另一个。
    func searchHF() {
        let q = hfQuery
        hfSearching = true
        hfError = nil
        Task {
            async let hf: [HFModel]? = try? HFSearch.search(q, limit: 50)
            async let ms: [MSModel]? = try? MSSearch.search(q, limit: 50)
            let (hfR, msR) = await (hf, ms)

            await MainActor.run {
                self.hfSearching = false
                self.hfSearched = true
                if let r = hfR { self.hfResults = r }
                if let r = msR { self.msResults = r }
                if hfR == nil && msR == nil {
                    self.hfError = "双源都失败。HuggingFace 走 hf-mirror 镜像，魔搭直连，请检查网络。"
                } else if hfR == nil || msR == nil {
                    self.hfError = "部分源失败：\(hfR == nil ? "HuggingFace" : "魔搭") 未返回结果。"
                } else {
                    self.hfError = nil
                }
            }
        }
    }

    /// 打开某个 HF 模型的详情页（浏览器）
    func openHFModel(_ modelId: String) {
        if let u = URL(string: "https://hf-mirror.com/\(modelId)") {
            NSWorkspace.shared.open(u)
        }
    }

    /// 把某个 HF 模型仓库的 .gguf 文件下载到本地（走 huggingface-cli 或直链）。
    /// 这里用 `huggingface-cli download`（若装了）或引导用户手动下。
    /// 通过 HF_ENDPOINT 让 huggingface-cli 走 hf-mirror 镜像，否则国内直连会失败。
    func downloadHF(_ modelId: String) {
        let p = Sh.find("huggingface-cli") ?? Sh.find("hf")
        if let cli = p {
            busy = "下载 \(modelId)"
            log = ""
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: cli)
                proc.arguments = ["download", modelId, "--include", "*.gguf"]
                var env = ProcessInfo.processInfo.environment
                env["HF_ENDPOINT"] = "https://hf-mirror.com"
                proc.environment = env
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe
                pipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if !d.isEmpty, let s = String(data: d, encoding: .utf8) {
                        DispatchQueue.main.async { self.log += s }
                    }
                }
                try? proc.run()
                proc.waitUntilExit()
                pipe.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async {
                    self.busy = nil
                    let ok = proc.terminationStatus == 0
                    self.log += ok ? "\n[完成] 已下载 \(modelId)\n" : "\n[失败] 退出码 \(proc.terminationStatus)\n"
                    if ok { self.toast = "已下载 \(modelId)，可到「导入 GGUF」注册" }
                }
            }
        } else {
            // 未装 huggingface-cli，引导安装或去网页下
            openHFModel(modelId)
            toast = "未检测到 huggingface-cli。已打开网页，可在 Files 里下 GGUF 后用「导入 GGUF」注册（或 pip install -U huggingface_hub）"
        }
    }

    // MARK: - 魔搭应用内直下

    /// 打开某个魔搭仓库的文件列表弹层（点「下载」时调用）。
    func listMSFiles(_ model: MSModel) {
        msListing = MSListing(org: model.path, name: model.name, model: model)
        msFiles = []
        msFilesLoading = true
        Task {
            do {
                let files = try await MSDownload.listFiles(org: model.path, name: model.name)
                await MainActor.run {
                    self.msFiles = files
                    self.msFilesLoading = false
                }
            } catch {
                await MainActor.run {
                    self.msFilesLoading = false
                    self.toast = "读取文件列表失败：\(error.localizedDescription)"
                }
            }
        }
    }

    /// 下载目录：~/Downloads/MindModel（不存在则建）。
    static func downloadDir() -> URL {
        let dl = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = dl.appendingPathComponent("MindModel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 应用内直下魔搭的某个 .gguf 文件，完成后自动解析并加入导入列表。
    func downloadMSFile(_ file: MSFile) {
        guard let listing = msListing else { return }
        let dir = Self.downloadDir()
        msDownloading = (path: file.path, received: 0, total: file.size)
        Task {
            do {
                let saved = try await MSDownload.download(
                    org: listing.org, name: listing.name, filePath: file.path, to: dir
                ) { recv, total in
                    Task { @MainActor in
                        self.msDownloading = (path: file.path, received: recv, total: total)
                    }
                }
                await MainActor.run {
                    self.msDownloading = nil
                    self.msDownloaded = saved
                    self.toast = "已下载 \(file.path)，正在解析…"
                    // 直接走导入解析，把下载的 gguf 识别出来
                    self.loadGGUF(paths: [saved.path])
                }
            } catch {
                await MainActor.run {
                    self.msDownloading = nil
                    self.toast = "下载失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func openInstalledApp(_ name: String) {
        for e in engines where e.name == name && e.ready {
            // 命令行工具（如 sd/sd-server）不是可双击的应用，打开文档页而非文件
            if e.name == "stable-diffusion.cpp" || e.name == "llama.cpp" {
                if let u = URL(string: e.installURL) { NSWorkspace.shared.open(u) }
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: e.path))
            }
            return
        }
        if let e = engines.first(where: { $0.name == name }), let u = URL(string: e.installURL) {
            NSWorkspace.shared.open(u)
        }
    }

    // MARK: - GGUF

    func pickGGUF() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if let t = UTType(filenameExtension: "gguf") { panel.allowedContentTypes = [t] }
        panel.message = "选择 .gguf：只选主模型即可，投影器与其余分片会自动在同目录配对"
        if panel.runModal() == .OK { loadGGUF(paths: panel.urls.map { $0.path }) }
    }

    func loadGGUF(paths: [String]) {
        guard !paths.isEmpty else { return }
        busy = "解析 GGUF 头部"
        let picked = paths
        DispatchQueue.global(qos: .userInitiated).async {
            var parsed: [String: GGUFInfo] = [:]
            for p in picked where parsed[p] == nil {
                if let info = GGUF.parse(path: p) { parsed[p] = info }
            }
            var items: [ImportItem] = []
            for p in picked {
                guard let info = parsed[p], !info.isProjector else { continue }
                let b = Self.assemble(info, parsed: parsed, picked: picked)
                items.append(ImportItem(bundle: b, name: OllamaName.normalize(info.fileName)))
            }
            if items.isEmpty {
                for p in picked {
                    guard let info = parsed[p], info.isProjector else { continue }
                    let b = Self.assembleProjectorOnly(info, parsed: parsed)
                    items.append(ImportItem(bundle: b, name: OllamaName.normalize(info.fileName)))
                }
            }
            DispatchQueue.main.async {
                self.imports.append(contentsOf: items)
                self.busy = nil
                self.toast = items.isEmpty
                    ? "未识别出主模型：若这是 mmproj 投影器，请同时选择同目录的主模型"
                    : "已识别 \(items.count) 个模型"
            }
        }
    }

    /// 同目录扫描：其余分片 + 所有 mmproj
    nonisolated static func scanSiblings(of path: String) -> (shards: [String], projectors: [String]) {
        let dir = (path as NSString).deletingLastPathComponent
        let me = (path as NSString).lastPathComponent
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.lowercased().hasSuffix(".gguf") }
        var shards: [String] = []
        if let sp = splitToken(me) {
            shards = files
                .filter { f in
                    guard let o = splitToken(f) else { return false }
                    return o.prefix == sp.prefix && o.count == sp.count
                }
                .sorted { (splitToken($0)?.no ?? 0) < (splitToken($1)?.no ?? 0) }
                .map { dir + "/" + $0 }
        }
        let projectors = files
            .filter { $0.lowercased().contains("mmproj") }
            .sorted()
            .map { dir + "/" + $0 }
        return (shards, projectors)
    }

    /// 文件名/架构上看像不像视觉模型（用于提示"缺投影器"，措辞保持保守）
    nonisolated static func looksVision(_ i: GGUFInfo) -> Bool {
        let n = i.fileName.lowercased()
        let a = i.arch.lowercased()
        if a.contains("clip") { return true }
        for t in ["-vl", "vl-", "vision", "llava", "mllama", "pixtral", "internvl", "minicpm-v", "gemma3"] {
            if n.contains(t) { return true }
        }
        return a == "llava" || a == "mllama" || a.contains("vl")
    }

    nonisolated static func assemble(_ info: GGUFInfo, parsed: [String: GGUFInfo], picked: [String]) -> ModelBundle {
        let sib = scanSiblings(of: info.path)
        var projectors = sib.projectors
        for p in picked where p.lowercased().contains("mmproj") {
            projectors.removeAll { $0 == p }
            projectors.insert(p, at: 0)
        }
        var pj: GGUFInfo? = nil
        if let first = projectors.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            pj = parsed[first] ?? GGUF.parse(path: first)
        }
        var b = ModelBundle(main: info, projector: pj, shards: sib.shards)
        b.suspectVision = looksVision(info)
        b.missingProjector = b.suspectVision && pj == nil
        return b
    }

    nonisolated static func assembleProjectorOnly(_ pj: GGUFInfo, parsed: [String: GGUFInfo]) -> ModelBundle {
        // 反向配对：同目录找非 mmproj 的第一个 gguf 当主模型
        let dir = (pj.path as NSString).deletingLastPathComponent
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.lowercased().hasSuffix(".gguf") && !$0.lowercased().contains("mmproj") }
            .sorted()
        let mainInfo = files.first.flatMap { parsed[dir + "/" + $0] ?? GGUF.parse(path: dir + "/" + $0) }
        var b = ModelBundle(main: mainInfo ?? pj, projector: pj, shards: [])
        b.missingProjector = mainInfo == nil
        b.onlyProjectorSelected = mainInfo == nil
        return b
    }

    // MARK: - 导入队列

    func renameImport(path: String, to name: String) {
        guard let i = imports.firstIndex(where: { $0.id == path }) else { return }
        imports[i].name = name
        if case .failed = imports[i].status { imports[i].status = .idle }
    }

    func removeImport(path: String) {
        imports.removeAll { $0.id == path }
    }

    func clearImports() {
        imports.removeAll()
        queue.removeAll()
    }

    /// 同名模型是否已存在（注册会覆盖它）
    func nameTaken(_ name: String) -> Bool {
        installed.contains { $0.name == name }
    }

    /// 把这一项能注册吗——不能则返回原因，界面直接显示
    nonisolated static func blockReason(_ item: ImportItem, ollamaReady: Bool) -> String? {
        let b = item.bundle
        if !ollamaReady { return "未检测到 Ollama，先装好再导入" }
        if b.onlyProjectorSelected { return "只找到投影器，缺主模型文件" }
        if b.main.splitCount > 1 && b.shards.count < b.main.splitCount {
            return "分片不全（\(b.shards.count)/\(b.main.splitCount)），把其余分片放到同目录"
        }
        if let p = OllamaName.problem(item.name) { return "模型名不合法：\(p)" }
        return nil
    }

    @Published var queue: [String] = []
    private var pumping = false

    func register(_ paths: [String]) {
        let list = paths.isEmpty ? imports.filter { $0.status == .idle }.map { $0.id } : paths
        guard !list.isEmpty else { return }
        queue.append(contentsOf: list)
        pump()
    }

    private func pump() {
        guard !pumping else { return }
        guard !queue.isEmpty else {
            busy = nil
            let ok = imports.filter { if case .ok = $0.status { return true }; return false }.count
            if ok > 0 { toast = "已注册 \(ok) 个模型" }
            return
        }
        pumping = true
        let path = queue.removeFirst()
        runRegister(path) { [weak self] in
            guard let self else { return }
            self.pumping = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.pump() }
        }
    }

    private func setStatus(_ path: String, _ st: ImportStatus) {
        guard let i = imports.firstIndex(where: { $0.id == path }) else { return }
        imports[i].status = st
    }

    private func runRegister(_ path: String, done: @escaping () -> Void) {
        guard let item = imports.first(where: { $0.id == path }) else { done(); return }
        if let why = Self.blockReason(item, ollamaReady: ollamaPath != nil) {
            setStatus(path, .failed(why))
            done()
            return
        }
        guard let exe = ollamaPath else { done(); return }
        let b = item.bundle
        let name = item.name

        // 分片时 FROM 指向第一片，llama.cpp 会按命名自动加载其余片
        var mainPath = b.main.path
        if b.main.splitCount > 1,
           let first = b.shards.first(where: { (splitToken(($0 as NSString).lastPathComponent)?.no ?? 9) == 1 }) {
            mainPath = first
        }

        // 上下文：不超过模型原生长度，也不超过 32K（再大对多数机器是负担）
        let nativeCtx = b.main.contextLength
        let ctx = nativeCtx > 0 ? min(nativeCtx, 32768) : 8192

        var modelfile = "FROM \(mainPath)\n"
        if let pj = b.projector { modelfile += "FROM \(pj.path)\n" }
        modelfile += "PARAMETER num_ctx \(ctx)\nPARAMETER temperature 0.8\n"

        let tmp = NSTemporaryDirectory() + "mindmodel-\(UUID().uuidString).Modelfile"
        try? modelfile.write(toFile: tmp, atomically: true, encoding: .utf8)

        setStatus(path, .running)
        busy = "注册 \(name)"
        log = ""
        if b.projector != nil {
            log += "视觉投影器：\(b.projector?.path ?? "")\n"
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let r = Sh.exec(exe, ["create", name, "-f", tmp])
            try? FileManager.default.removeItem(atPath: tmp)
            DispatchQueue.main.async {
                self.log += r.text
                if r.code == 0 {
                    self.setStatus(path, .ok(name))
                    self.log += "\n[完成] ollama run \(name)\n"
                } else {
                    self.setStatus(path, .failed(Self.shortReason(r.text, code: r.code)))
                }
                self.refreshInstalled()
                self.scanDisk()
                done()
            }
        }
    }

    /// 把 ollama 的长输出压成一句能显示的原因
    nonisolated static func shortReason(_ text: String, code: Int32) -> String {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for l in lines.reversed() where l.lowercased().contains("error") {
            return l.count > 90 ? String(l.prefix(90)) + "…" : l
        }
        if let last = lines.last { return last.count > 90 ? String(last.prefix(90)) + "…" : last }
        return "退出码 \(code)，没有输出"
    }

    // MARK: - 模型仓库

    enum ModelSort: String, CaseIterable, Identifiable {
        case size = "按体积"
        case name = "按名称"
        case time = "按时间"
        var id: String { rawValue }
    }

    /// 只读扫描 ollama 的 manifests 与 blobs，顺带产出体检结论
    func scanDisk() {
        auditing = true
        let budget = budgetGB
        DispatchQueue.global(qos: .utility).async {
            let d = ModelAudit.scan()
            let list = d.issues(budgetGB: budget)
            DispatchQueue.main.async {
                self.disk = d
                self.issues = list
                self.auditing = false
            }
        }
    }

    var visibleModels: [InstalledModel] {
        var list = installed
        let q = searchModel.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty { list = list.filter { $0.name.lowercased().contains(q) } }
        switch sortBy {
        case .size: list.sort { $0.sizeGB > $1.sizeGB }
        case .name: list.sort { $0.name < $1.name }
        case .time: list.sort { $0.modified > $1.modified }
        }
        return list
    }

    /// 已装模型对应的仓库元数据（量化、参数量、能力），来自 manifest 的 config blob
    func manifest(_ name: String) -> OllamaManifest? {
        disk.manifests.first { $0.name == name }
    }

    func togglePick(_ m: InstalledModel) {
        if picked.contains(m.id) { picked.remove(m.id) } else { picked.insert(m.id) }
    }

    var pickedModels: [InstalledModel] {
        installed.filter { picked.contains($0.id) }
    }

    var pickedGB: Double { pickedModels.reduce(0) { $0 + $1.sizeGB } }

    /// 删除是不可逆操作：这里只准备清单，真正执行要用户在弹窗里再确认
    func requestDelete(_ list: [InstalledModel]) {
        let ok = list.filter { $0.deletable }
        guard !ok.isEmpty else {
            toast = "这些模型不在 Ollama 目录下，本应用不代为删除"
            return
        }
        pendingDelete = ok
        confirmDelete = true
    }

    func performDelete() {
        let list = pendingDelete.filter { $0.deletable }
        pendingDelete = []
        guard let exe = ollamaPath, !list.isEmpty else { return }
        busy = "删除模型"
        log = ""
        let names = list.map { $0.name }
        DispatchQueue.global(qos: .userInitiated).async {
            var failed: [String] = []
            for n in names {
                let r = Sh.exec(exe, ["rm", n])
                if r.code != 0 { failed.append("\(n)：\(Self.shortReason(r.text, code: r.code))") }
            }
            DispatchQueue.main.async {
                self.busy = nil
                if failed.isEmpty {
                    self.toast = "已删除 \(names.count) 个模型"
                } else {
                    self.toast = "有 \(failed.count) 个没删掉，见日志"
                    self.log = failed.joined(separator: "\n")
                }
                self.picked.removeAll()
                self.refreshInstalled()
                self.scanDisk()
            }
        }
    }

    func revealModel(_ m: InstalledModel) {
        let target = m.path.isEmpty
            ? (ModelAudit.root + "/manifests")
            : m.path
        NSWorkspace.shared.selectFile(target, inFileViewerRootedAtPath: "")
    }

    /// 选整个文件夹：把目录里的 gguf 一次性入队（只扫描这一层）
    func pickGGUFFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择放 .gguf 的目录，本层所有模型会被加入队列"
        guard panel.runModal() == .OK, let dir = panel.urls.first else { return }
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".gguf") }
            .sorted()
            .map { dir.path + "/" + $0 }
        guard !files.isEmpty else {
            toast = "这个目录里没有 .gguf 文件"
            return
        }
        loadGGUF(paths: files)
    }

    func pickAgentCwd() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择智能体的工作目录（读文件、搜索默认从这里开始）"
        guard panel.runModal() == .OK, let dir = panel.urls.first else { return }
        agentCwd = dir.path
    }

    // MARK: - 对话

    /// 能对话的模型：Ollama 里的都算，但纯嵌入模型排除
    var chatModels: [InstalledModel] {
        installed.filter { m in
            guard m.engine == "Ollama" else { return false }
            if let man = manifest(m.name) {
                if man.capabilities.contains("embedding") && !man.capabilities.contains("completion") {
                    return false
                }
            }
            return true
        }
    }

    func attachImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .heic, .webP]
        panel.message = "选图片发给视觉模型（纯文本模型会忽略）"
        guard panel.runModal() == .OK else { return }
        for u in panel.urls {
            guard let d = try? Data(contentsOf: u) else { continue }
            if d.count > 8 * 1024 * 1024 {
                toast = "\(u.lastPathComponent) 超过 8 MB，先压一下再发"
                continue
            }
            pendingImages.append(d.base64EncodedString())
        }
    }

    func stopChat() {
        chatTask?.cancel()
        chatTask = nil
        chatBusy = false
    }

    func clearChat() {
        stopChat()
        chat.removeAll()
        chatError = nil
    }

    func sendChat() {
        let text = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingImages.isEmpty else { return }
        guard !chatModel.isEmpty else { chatError = "先选一个模型"; return }
        guard !chatBusy else { return }

        chat.append(ChatMsg(role: "user", text: text, images: pendingImages))
        let imgCount = pendingImages.count
        pendingImages = []
        chatInput = ""
        chat.append(ChatMsg(role: "assistant", text: ""))
        let idx = chat.count - 1
        chatBusy = true
        chatError = nil

        var msgs: [[String: Any]] = []
        for m in chat.dropLast() {
            var one: [String: Any] = ["role": m.role, "content": m.text]
            if !m.images.isEmpty { one["images"] = m.images }
            msgs.append(one)
        }
        let model = chatModel
        let ctx = chatCtx

        chatTask = Task { [weak self] in
            guard let self else { return }
            guard let url = URL(string: "http://127.0.0.1:11434/api/chat") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 600
            let body: [String: Any] = [
                "model": model,
                "messages": msgs,
                "stream": true,
                "options": ["num_ctx": ctx, "temperature": 0.7],
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)

            do {
                let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                if code != 200 {
                    var detail = ""
                    for try await line in bytes.lines { detail += line }
                    self.chat[idx].text = "调用失败（HTTP \(code)）"
                    self.chatError = detail.isEmpty ? "Ollama 服务是否在运行？" : detail
                    self.chatBusy = false
                    return
                }
                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    guard let d = line.data(using: .utf8),
                          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                    if let piece = (o["message"] as? [String: Any])?["content"] as? String, !piece.isEmpty {
                        self.chat[idx].text += piece
                    }
                    if o["done"] as? Bool == true {
                        let ec = (o["eval_count"] as? NSNumber)?.doubleValue ?? 0
                        let ed = (o["eval_duration"] as? NSNumber)?.doubleValue ?? 0
                        if ec > 0, ed > 0 {
                            // 对话里顺手记一版速度：上下文里有图片和长 prompt，
                            // 通常比 160 token 的标准实测偏低，但仍是这台机器上的真实数
                            let tps = ec / (ed / 1_000_000_000)
                            let pc = (o["prompt_eval_count"] as? NSNumber)?.doubleValue ?? 0
                            let pd = (o["prompt_eval_duration"] as? NSNumber)?.doubleValue ?? 0
                            self.benchRecords[model] = BenchRecord(
                                model: model, tps: tps,
                                prefill: pd > 0 ? pc / (pd / 1_000_000_000) : 0,
                                tokens: Int(ec), at: Date(),
                                note: String(format: "对话记录 · %d tokens，含 %d 张图",
                                             Int(ec), imgCount))
                        }
                    }
                }
            } catch {
                if !Task.isCancelled {
                    self.chatError = error.localizedDescription
                    if self.chat[idx].text.isEmpty { self.chat[idx].text = "（没有收到回复）" }
                }
            }
            self.chatBusy = false
        }
    }

    // MARK: - 智能体

    /// 一次模型调用：非流式，带工具定义。返回（文本，工具调用列表，是否结束）。
    /// 用非流式是为了拿到完整 tool_calls；对话页用流式是为了逐字显示。
    private func agentCall(model: String, messages: [[String: Any]]) async
        -> (text: String, calls: [ToolCall], done: Bool)? {
        guard let url = URL(string: "http://127.0.0.1:11434/api/chat") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "tools": AgentTools.definitions,
            "stream": false,
            "options": ["num_ctx": 8192, "temperature": 0.3],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else {
                let detail = String(data: data, encoding: .utf8) ?? ""
                return (text: "调用失败（HTTP \(code)）：\(detail.prefix(300))", calls: [], done: false)
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (text: "返回无法解析", calls: [], done: false)
            }
            let msg = obj["message"] as? [String: Any] ?? [:]
            let text = msg["content"] as? String ?? ""
            let done = (obj["done"] as? Bool) ?? false
            var calls: [ToolCall] = []
            if let tc = msg["tool_calls"] as? [[String: Any]] {
                for c in tc {
                    if let f = c["function"] as? [String: Any],
                       let name = f["name"] as? String {
                        var args: [String: String] = [:]
                        // arguments 可能是对象，也可能是 JSON 字符串，两种都接
                        if let a = f["arguments"] as? [String: Any] {
                            for (k, v) in a { args[k] = String(describing: v) }
                        } else if let s = f["arguments"] as? String,
                                  let data = s.data(using: .utf8),
                                  let a = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            for (k, v) in a { args[k] = String(describing: v) }
                        }
                        calls.append(ToolCall(name: name, arguments: args))
                    }
                }
            }
            return (text, calls, done)
        } catch {
            return (text: "调用出错：\(error.localizedDescription)", calls: [], done: false)
        }
    }

    /// 跑一轮智能体：模型可以反复调用工具，直到给出最终答复或步数用尽。
    func runAgent(task: String) {
        guard !agentBusy else { return }
        guard !agentModel.isEmpty else { agentError = "先选一个模型"; return }
        agentBusy = true
        agentError = nil
        agentSteps = []
        let model = agentModel
        let cwd = agentCwd

        agentTask = Task { [weak self] in
            guard let self else { return }
            var messages: [[String: Any]] = [
                ["role": "system", "content": """
                你是运行在本机的一个智能体，负责完成用户交给你的任务。工作目录是 \(cwd)。
                规则：
                1. 能自己动手的（读文件、列目录、搜索）直接调用工具；需要写文件或执行命令时先规划好，一次只做一个有把握的动作。
                2. 每个工具调用前想清楚参数对不对，尤其是绝对路径。
                3. 拿到工具结果后，判断是否还需要继续；不需要了就给出最终答复，不要再调用工具。
                4. 最终答复要直接回答用户的问题，说清楚你做了什么、结论是什么。
                5. 不要编造文件内容或命令输出；拿不到的信息就直说拿不到。
                """],
                ["role": "user", "content": task],
            ]

            var finalAnswer = ""
            let maxSteps = 12

            for step in 1...maxSteps {
                if Task.isCancelled { break }
                guard let r = await self.agentCall(model: model, messages: messages) else {
                    self.agentError = "调用失败，请确认 Ollama 在运行"
                    break
                }
                // 记录模型这一步的想法/答复
                if !r.text.isEmpty {
                    if r.calls.isEmpty {
                        finalAnswer = r.text
                        self.agentSteps.append(AgentStep(kind: .answer, title: "答复", detail: r.text))
                        break
                    } else {
                        self.agentSteps.append(AgentStep(kind: .thought, title: "第 \(step) 步", detail: r.text))
                    }
                }
                // 没有工具调用 = 结束
                if r.calls.isEmpty {
                    if finalAnswer.isEmpty { finalAnswer = "（模型没有给出文字答复）" }
                    break
                }
                // 执行工具
                for call in r.calls {
                    if Task.isCancelled { break }
                    // 写文件/命令需要确认；纯读直接执行
                    let risky = (call.name == "write_file" || call.name == "run_command")
                    if risky && !self.agentAllowWrite {
                        let approved = await self.confirmTool(call)
                        if !approved {
                            self.agentSteps.append(AgentStep(
                                kind: .result, title: call.name,
                                detail: "已拒绝执行（用户未授权）"))
                            messages.append(self.toolMsg(call, ok: false,
                                                          output: "用户拒绝执行这个操作"))
                            continue
                        }
                    }
                    let res = AgentExecutor.execute(call)
                    self.agentSteps.append(AgentStep(
                        kind: res.ok ? .tool : .result,
                        title: call.name,
                        detail: res.output.isEmpty ? "（空）" : res.output))
                    messages.append(self.toolMsg(call, ok: res.ok, output: res.output))
                }
                // 把模型这轮的 tool_calls 也回传，保持消息流完整
                messages.append(self.assistantToolMsg(calls: r.calls))
            }

            if finalAnswer.isEmpty && !self.agentSteps.isEmpty {
                finalAnswer = "（达到步数上限，未给出最终答复）"
                self.agentSteps.append(AgentStep(kind: .answer, title: "答复", detail: finalAnswer))
            }
            self.agentBusy = false
        }
    }

    private func toolMsg(_ call: ToolCall, ok: Bool, output: String) -> [String: Any] {
        return [
            "role": "tool",
            "name": call.name,
            "content": output,
        ]
    }

    private func assistantToolMsg(calls: [ToolCall]) -> [String: Any] {
        let tc: [[String: Any]] = calls.map { c in
            ["function": ["name": c.name, "arguments": c.arguments]]
        }
        return ["role": "assistant", "tool_calls": tc]
    }

    /// 弹确认框，等用户决定是否允许写文件/执行命令。返回是否批准。
    @MainActor
    private func confirmTool(_ call: ToolCall) async -> Bool {
        agentPendingConfirm = call
        agentConfirmChoice = false
        // 等待用户在 UI 上点允许/拒绝
        while agentPendingConfirm != nil && !agentConfirmChoice {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let approved = agentConfirmChoice
        agentPendingConfirm = nil
        return approved
    }

    func resolveConfirm(_ allow: Bool) {
        agentConfirmChoice = allow
    }

    func stopAgent() {
        agentTask?.cancel()
        agentTask = nil
        agentBusy = false
    }

    // MARK: - 实测

    /// 一条实测记录。存下来的原因有两个：重启后仍以实测速度为准；
    /// 以及能看出同一模型两次测量之间的漂移（内存压力、后台任务都会影响）。
    struct BenchRecord: Codable, Identifiable {
        var id: String { model }
        var model: String
        var tps: Double
        var prefill: Double
        var tokens: Int
        var at: Date
        var note: String
    }

    func runBench(model: String) async {
        benchRunning = model
        benchMsg = "正在生成 160 tokens…"
        defer { benchRunning = nil }
        guard let url = URL(string: "http://127.0.0.1:11434/api/generate") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600
        let body: [String: Any] = [
            "model": model,
            "prompt": "用三句话解释什么是情感计算。",
            "stream": false,
            "options": ["num_predict": 160, "temperature": 0.7]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                benchMsg = "返回内容无法解析"
                return
            }
            let ec = (obj["eval_count"] as? NSNumber)?.doubleValue ?? 0
            let ed = (obj["eval_duration"] as? NSNumber)?.doubleValue ?? 0
            let pc = (obj["prompt_eval_count"] as? NSNumber)?.doubleValue ?? 0
            let pd = (obj["prompt_eval_duration"] as? NSNumber)?.doubleValue ?? 0
            if ec > 0, ed > 0 {
                let tps = ec / (ed / 1_000_000_000.0)
                let ptps = pd > 0 ? pc / (pd / 1_000_000_000.0) : 0
                let old = benchRecords[model]
                var note = ""
                if let o = old, o.tokens == Int(ec) {
                    let d = (tps - o.tps) / max(1, o.tps) * 100
                    if abs(d) >= 5 { note = String(format: "比上次 %+.0f%%", d) }
                }
                if let m = installed.first(where: { $0.name == model }), m.sizeGB > 0 {
                    note += note.isEmpty ? "" : " · "
                    note += String(format: "%.1f GB 权重", m.sizeGB)
                }
                benchRecords[model] = BenchRecord(model: model, tps: tps, prefill: ptps,
                                                  tokens: Int(ec), at: Date(), note: note)
                benchMsg = String(format: "生成 %.1f tok/s · 预填充 %.0f tok/s · %d tokens",
                                  tps, ptps, Int(ec))
            } else {
                benchMsg = "返回中缺少 eval 统计，请确认模型已加载"
            }
        } catch {
            benchMsg = "调用失败：\(error.localizedDescription)（Ollama 服务是否在运行？）"
        }
    }

    func benchmark(model: String) {
        Task { await runBench(model: model) }
    }

    /// 逐个跑完已装模型。串行是故意的：并发会让带宽争抢，测出来的数都偏低。
    func benchmarkAll() {
        guard benchQueue == nil else { return }
        Task {
            let targets = installed.filter { $0.engine == "Ollama" && !isCloud($0) }.map { $0.name }
            guard !targets.isEmpty else { benchMsg = "没有可实测的本地模型"; return }
            benchQueue = (done: 0, total: targets.count)
            for (i, name) in targets.enumerated() {
                benchQueue = (done: i, total: targets.count)
                await runBench(model: name)
            }
            benchQueue = nil
            benchMsg = "全部 \(targets.count) 个跑完"
        }
    }

    func clearBench(_ model: String) {
        benchRecords.removeValue(forKey: model)
    }

    /// 从已装模型名反查内置清单条目，用来给实测值配一个估算值做对照。
    /// 同名直接命中；否则按家族 + 参数量就近配，差超过 25% 视为清单外的模型
    /// （自己转换的 GGUF 经常不在清单里，这时不要硬凑一个估算值）。
    func catalogEntry(_ name: String) -> LocalModel? {
        let lower = name.lowercased()
        if let hit = Catalog.all.first(where: { $0.name.lowercased() == lower }) { return hit }
        let base = lower.split(separator: ":").first.map(String.init) ?? lower
        let family = base.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." })
            .first.map(String.init) ?? base
        let tag = lower.contains(":") ? String(lower.split(separator: ":").dropFirst().first ?? "") : ""
        let wanted = paramNumber(tag) ?? paramNumber(base)
        let same = Catalog.all.filter { $0.name.lowercased().contains(family) }
        guard !same.isEmpty else { return nil }
        guard let w = wanted else { return same.count == 1 ? same[0] : nil }
        guard let best = same.min(by: { abs($0.paramsB - w) < abs($1.paramsB - w) }) else { return nil }
        return abs(best.paramsB - w) / max(1, w) < 0.25 ? best : nil
    }

    /// 从 "70b" / "0.6b" 这类标签里取参数量
    private func paramNumber(_ s: String) -> Double? {
        var buf = ""
        for ch in s {
            if ch.isNumber || ch == "." { buf.append(ch) }
            else if ch == "b" {
                if let v = Double(buf), v > 0 { return v }
                buf = ""
            } else { buf = "" }
        }
        return nil
    }

    // MARK: - 报告

    func exportReport() {
        var s = "# MindModel 本机体检报告\n\n"
        s += "生成时间：\(Date())\n\n"
        s += "## 硬件\n\n"
        s += "| 项 | 值 |\n|---|---|\n"
        s += "| 芯片 | \(hw.chip) |\n"
        s += "| 机型 | \(hw.model) |\n"
        s += "| 系统 | \(hw.osVersion) |\n"
        s += "| CPU 核心 | \(hw.totalCores)（性能 \(hw.perfCores) / 能效 \(hw.effCores)） |\n"
        s += "| GPU | \(hw.gpuName) · \(hw.gpuCores) 核 |\n"
        s += "| 统一内存 | \(String(format: "%.0f", hw.ramGB)) GB |\n"
        s += "| Metal 建议工作集 | \(String(format: "%.1f", hw.metalWorkingSetGB)) GB |\n"
        s += "| 实测内存带宽 | \(bandwidth.map { String(format: "%.0f GB/s", $0) } ?? "未测") |\n"
        s += "| 磁盘可用 | \(String(format: "%.0f", hw.diskFreeGB)) GB |\n\n"
        s += "## 推荐（上下文 \(contextTokens) tokens）\n\n"
        s += "| 模型 | 参数 | Q4 体积 | 需求 | 判定 | 估算 tok/s |\n|---|---|---|---|---|---|\n"
        for a in ranked.prefix(20) where a.level != .tooHeavy {
            s += String(format: "| %@ | %.1fB | %.1f GB | %.1f GB | %@ | %.0f |\n",
                        a.model.name, a.model.paramsB, a.model.q4GB, a.needGB,
                        a.level.label, a.estTokS)
        }
        s += "\n## 已装模型\n\n"
        for m in installed {
            s += "- \(m.name) · \(String(format: "%.1f", m.sizeGB)) GB · \(m.engine)\n"
        }
        if !benchRecords.isEmpty {
            s += "\n## 实测记录\n\n| 模型 | 实测 tok/s | 预填充 tok/s | tokens | 时间 |\n|---|---|---|---|---|\n"
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            for r in benchRecords.values.sorted(by: { $0.tps > $1.tps }) {
                s += String(format: "| %@ | %.1f | %.0f | %d | %@ |\n",
                            r.model, r.tps, r.prefill, r.tokens, f.string(from: r.at))
            }
        }
        s += "\n> 体积与适配参考 localmodel.run（2026-11）；速度为估算，实测值以本机运行为准。\n"
        let path = NSHomeDirectory() + "/Desktop/MindModel体检报告-\(Int(Date().timeIntervalSince1970)).md"
        try? s.write(toFile: path, atomically: true, encoding: .utf8)
        toast = "已导出到桌面"
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: NSHomeDirectory() + "/Desktop")
    }
}

@main
struct MindModelApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .frame(minWidth: 1040, minHeight: 700)
                .onAppear {
                    if state.hw.ramGB == 0 { state.boot() }
                    // 自动化视觉回归：MM_SNAPSHOT=<path> 时把当前界面离屏渲染成 PNG 后退出。
                    // 不依赖窗口焦点与录屏权限，CI 里也能跑。
                    if let out = ProcessInfo.processInfo.environment["MM_SNAPSHOT"] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                            let w = Double(ProcessInfo.processInfo.environment["MM_SNAP_W"] ?? "") ?? 900
                            let view = PageStack().environmentObject(state)
                                .frame(width: w)
                                .padding(18)
                                .background(Color(nsColor: .windowBackgroundColor))
                            let r = ImageRenderer(content: view)
                            r.scale = 2
                            if let img = r.nsImage,
                               let tiff = img.tiffRepresentation,
                               let rep = NSBitmapImageRep(data: tiff),
                               let png = rep.representation(using: .png, properties: [:]) {
                                try? png.write(to: URL(fileURLWithPath: out))
                            }
                            NSApp.terminate(nil)
                        }
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
