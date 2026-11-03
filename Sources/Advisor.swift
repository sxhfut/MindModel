import Foundation

/// 用途 → 候选池。放在纯逻辑层，UI 与命令行共用同一份判定。
enum Purpose: String, CaseIterable, Identifiable {
    case writing = "中文写作"
    case coding = "写代码"
    case reasoning = "深度推理"
    case vision = "看图"
    case longDoc = "长文档 128K"
    case alwaysOn = "后台常驻"

    var id: String { rawValue }

    var categories: [ModelCategory] {
        switch self {
        case .writing: return [.chat]
        case .coding: return [.code, .agent]
        case .reasoning: return [.reason, .chat]
        case .vision: return [.vision]
        case .longDoc: return [.chat, .code, .reason]
        case .alwaysOn: return [.light, .chat]
        }
    }
}

/// 适配与速度推算。全部为纯函数，便于离线核对。
struct Advisor {
    var budgetGB: Double
    var bandwidth: Double          // 实测 GB/s；0 表示未测
    var contextTokens: Int
    var benchmarks: [String: Double] = [:]
    var ctxOptions: [Int] = [4096, 8192, 16384, 32768, 65536, 131072]

    /// 每生成 1 token 需要从内存读出的近似字节量（GB）
    /// MoE 只读激活专家，故按 activeB/paramsB 折算；dense 即全量。
    /// 不做人为下限钳制——钳制会把 30B-A3B 当成 6B，进而系统性地高估大 dense 模型。
    func bytesPerToken(_ m: LocalModel) -> Double {
        let share = m.activeB / max(1.0, m.paramsB)
        return m.q4GB * min(1.0, max(0.02, share)) + 0.25
    }

    func need(_ m: LocalModel, ctx: Int? = nil) -> Double {
        let c = Double(ctx ?? contextTokens)
        return m.q4GB + m.kv1k * (c / 1024.0) + 1.6   // 权重 + KV + 运行时
    }

    func ratio(_ m: LocalModel) -> Double { need(m) / max(1.0, budgetGB) }

    func level(_ m: LocalModel) -> FitLevel {
        let r = ratio(m)
        if r <= 0.40 { return .plenty }
        if r <= 0.72 { return .smooth }
        if r <= 0.92 { return .ok }
        if r <= 1.15 { return .tight }
        return .tooHeavy
    }

    /// tok/s ≈ 带宽 × 效率系数 ÷ 每 token 字节数。系数 0.45 为保守取值，实测会覆盖它。
    func estTokS(_ m: LocalModel) -> Double {
        if let real = benchmarks[m.name] { return real }
        let bw = bandwidth > 1 ? bandwidth : 400.0
        let tps = bw * 0.45 / max(0.3, bytesPerToken(m))
        return min(260.0, max(0.4, tps))
    }

    /// 仍满足"可运行"（占比 ≤92%）的最大上下文
    func maxContext(_ m: LocalModel) -> Int {
        for c in ctxOptions.sorted(by: >) {
            let g = m.q4GB + m.kv1k * (Double(c) / 1024.0) + 1.6
            if g / max(1.0, budgetGB) <= 0.92 { return c }
        }
        return 0
    }

    /// 交互场景的最低可用速度（tok/s）。低于此值不算"能用"，只算"装得下"。
    func minTokS(_ p: Purpose) -> Double {
        switch p {
        case .writing: return 12
        case .coding: return 15
        case .reasoning: return 6      // 思考型可容忍慢
        case .vision: return 12
        case .longDoc: return 8
        case .alwaysOn: return 30
        }
    }

    /// 该用途下"够快"的参考速度，用于规模-速度折中
    private func refTokS(_ p: Purpose) -> Double {
        switch p {
        case .writing: return 30
        case .coding: return 45
        case .reasoning: return 15
        case .vision: return 25
        case .longDoc: return 20
        case .alwaysOn: return 60
        }
    }

    /// 用途打分：规模按幂次折算（避免大模型无脑碾压），速度不足按幂次衰减。
    func score(_ m: LocalModel, _ p: Purpose) -> Double {
        let tps = estTokS(m)
        if p == .alwaysOn { return tps * 2.0 + m.paramsB * 0.4 }
        let sizeTerm = pow(m.paramsB, 0.8)
        let speedTerm = pow(min(1.0, tps / refTokS(p)), 0.8)
        return sizeTerm * speedTerm
    }

    func advice(_ m: LocalModel) -> Advice {
        Advice(model: m, needGB: need(m), ratio: ratio(m), level: level(m), estTokS: estTokS(m))
    }

    func ranked(category: ModelCategory? = nil) -> [Advice] {
        // 只有对话类模型参与排序：图像生成、语音、向量、重排不是"跑分更高的对话模型"
        var list = Catalog.all.filter { $0.cat.chattable }
        if let c = category { list = list.filter { $0.cat == c } }
        let scored = list.map { m -> (LocalModel, Double) in
            let f: Double
            switch level(m) {
            case .plenty: f = 0.95
            case .smooth: f = 1.0
            case .ok: f = 0.88
            case .tight: f = 0.42
            case .tooHeavy: f = 0.04
            }
            let moe = m.activeB < m.paramsB ? 1.12 : 1.0
            return (m, m.paramsB * f * moe)
        }
        return scored.sorted { $0.1 > $1.1 }.map { advice($0.0) }
    }

    func topMatches(_ p: Purpose, limit: Int = 3) -> [Advice] {
        var pool = Catalog.all.filter { $0.cat.chattable && p.categories.contains($0.cat) }
        if p == .alwaysOn { pool = pool.filter { $0.paramsB <= 14 } }
        pool = pool.filter { level($0) != .tooHeavy }
        if p == .longDoc { pool = pool.filter { maxContext($0) >= 131072 } }
        // 速度硬门槛：装得下但慢到不可用，不该出现在"推荐"里
        let gated = pool.filter { estTokS($0) >= minTokS(p) }
        if !gated.isEmpty { pool = gated }
        return pool.sorted { score($0, p) > score($1, p) }
            .prefix(limit).map { advice($0) }
    }

    func match(_ p: Purpose) -> (Advice, String)? {
        guard let a = topMatches(p, limit: 1).first else { return nil }
        let m = a.model
        var reason = String(format: "需 %.1f GB，占预算 %.0f%%；估算 %.0f tok/s",
                            a.needGB, a.ratio * 100, a.estTokS)
        if let b = benchmarks[m.name] {
            reason = String(format: "需 %.1f GB，占预算 %.0f%%；本机实测 %.1f tok/s",
                            a.needGB, a.ratio * 100, b)
        }
        let mc = maxContext(m)
        if mc > 0 { reason += "；可开至 \(mc / 1024)K 上下文" }
        if a.level == .plenty { reason += "；余量充足，可换 Q6/Q8 更高精度" }
        return (a, reason)
    }

    /// 本机建议档位：在"流畅/余量充足"里取最大参数
    var sweetSpot: String {
        let ok = Catalog.all.filter { $0.cat.chattable && (level($0) == .smooth || level($0) == .plenty) }
        guard let biggest = ok.max(by: { $0.paramsB < $1.paramsB }) else { return "—" }
        let moe = biggest.activeB < biggest.paramsB ? "-A\(Int(biggest.activeB))B" : ""
        return "≈\(Int(biggest.paramsB))B\(moe)"
    }

    func fitCount(_ models: [LocalModel]) -> Int {
        models.filter { $0.cat.chattable && level($0) != .tooHeavy }.count
    }
}

// MARK: - 角色与任务

enum WorkRole: String, CaseIterable, Identifiable {
    case researcher = "研究者"
    case engineer = "工程师"
    case teacher = "教师"
    case student = "学生"
    case manager = "管理者"
    case creator = "内容创作"

    var id: String { rawValue }

    var tasks: [WorkTask] {
        switch self {
        case .researcher: return [.paper, .litreview, .dataAnalysis, .affect, .peerReview, .summarize, .vision]
        case .engineer: return [.coding, .debugging, .dataAnalysis, .summarize, .vision, .daily]
        case .teacher: return [.teaching, .paper, .translation, .summarize, .vision, .daily]
        case .student: return [.paper, .litreview, .coding, .translation, .summarize, .daily]
        case .manager: return [.summarize, .dataAnalysis, .daily, .translation, .vision, .paper]
        case .creator: return [.paper, .translation, .summarize, .daily, .vision]
        }
    }
}

enum WorkTask: String, CaseIterable, Identifiable {
    case paper = "论文写作"
    case litreview = "文献调研"
    case coding = "代码实现"
    case debugging = "调试与重构"
    case dataAnalysis = "数据分析"
    case peerReview = "审稿意见"
    case teaching = "教学备课"
    case translation = "翻译校对"
    case affect = "情感计算实验"
    case daily = "日常问答"
    case vision = "图表截图理解"
    case summarize = "长文总结"

    var id: String { rawValue }

    /// 七维权重：中文、写作、代码、数理、工具、视觉、长上下文
    var weights: (zh: Double, writing: Double, code: Double, math: Double, tools: Double, vision: Double, follow: Double) {
        switch self {
        case .paper:        return (0.22, 0.38, 0.02, 0.14, 0.10, 0.02, 0.12)
        case .litreview:    return (0.18, 0.26, 0.04, 0.10, 0.22, 0.04, 0.16)
        case .coding:       return (0.04, 0.02, 0.52, 0.12, 0.24, 0.00, 0.06)
        case .debugging:    return (0.04, 0.02, 0.48, 0.20, 0.20, 0.00, 0.06)
        case .dataAnalysis: return (0.08, 0.04, 0.28, 0.42, 0.12, 0.00, 0.06)
        case .peerReview:   return (0.18, 0.24, 0.04, 0.18, 0.24, 0.00, 0.12)
        case .teaching:     return (0.26, 0.32, 0.06, 0.10, 0.14, 0.04, 0.08)
        case .translation:  return (0.28, 0.26, 0.02, 0.04, 0.14, 0.00, 0.26)
        case .affect:       return (0.16, 0.06, 0.30, 0.30, 0.12, 0.02, 0.04)
        case .daily:        return (0.34, 0.22, 0.04, 0.06, 0.18, 0.02, 0.14)
        case .vision:       return (0.14, 0.06, 0.02, 0.04, 0.10, 0.58, 0.06)
        case .summarize:    return (0.16, 0.20, 0.02, 0.04, 0.28, 0.02, 0.28)
        }
    }

    /// 该任务至少要撑到多少上下文
    var minContext: Int {
        switch self {
        case .coding, .debugging, .affect: return 32768
        case .paper, .litreview, .peerReview, .summarize, .translation: return 65536
        case .teaching, .dataAnalysis, .daily, .vision: return 16384
        }
    }

    /// 交互可用性的速度下限
    var minTokS: Double {
        switch self {
        case .paper, .teaching: return 12
        case .summarize, .litreview, .peerReview: return 15
        case .coding, .debugging: return 15
        case .daily: return 28
        case .dataAnalysis, .affect: return 8
        case .translation: return 10
        case .vision: return 10
        }
    }

    /// 该任务以中文产出为主：中文语感不足的模型不应夺冠
    var chineseHeavy: Bool {
        switch self {
        case .paper, .litreview, .peerReview, .teaching, .translation, .summarize, .daily:
            return true
        case .coding, .debugging, .dataAnalysis, .affect, .vision:
            return false
        }
    }

    /// 该任务要能看图吗（决定候选池是否按模态收窄）
    var needsVision: Bool { categories.contains(.vision) }

    /// 候选类别。注意：这**不是**硬门槛，只有 `.vision` 会用来收窄候选池；
    /// 其余任务不限类别——多模态模型同样是称职的文本模型，按类别乱砍会丢掉好候选。
    var categories: [ModelCategory] {
        switch self {
        case .coding, .debugging: return [.code, .agent]
        case .vision: return [.vision]
        case .dataAnalysis, .affect: return [.code, .reason, .chat]
        case .daily: return [.light, .chat, .agent]
        default: return [.chat, .code]
        }
    }

    /// 七维权重展开为数组，顺序与 `Capability.vector` 一致：中文、写作、代码、数理、工具、视觉、长文
    var rawWeights: [Double] {
        let w = weights
        return [w.zh, w.writing, w.code, w.math, w.tools, w.vision, w.follow]
    }

    var rationale: String {
        switch self {
        case .paper: return "写作权重最高，中文语感次之；上下文要够长"
        case .litreview: return "看指令遵循与长上下文，能不能扛住几十篇文献"
        case .coding: return "代码能力为主，工具调用次之"
        case .debugging: return "代码 + 数理推理并重，要能顺着报错推"
        case .dataAnalysis: return "数理推理为主，代码是实现手段"
        case .peerReview: return "指令遵循与数理判断并重，中文表达次之"
        case .teaching: return "中文表达与结构化写作"
        case .translation: return "双语语感与格式一致性"
        case .affect: return "数理 + 代码，跑实验多于写作"
        case .daily: return "响应速度与指令遵循优先，规模不必大"
        case .vision: return "图像理解为主，其余维度只做兜底"
        case .summarize: return "长上下文与要点提炼"
        }
    }
}

// MARK: - 多选任务合并

/// 多选任务的合并结果。合并规则（与 Rust 内核 `task.rs` 逐条一致）：
/// - **权重**：每个任务先归一化到 sum=1，再对选中任务取均值 —— 让权重可比，
///   否则原始权重之和不同的任务混在一起，等于偷偷给某些维度加权
/// - **上下文门槛**：取最大 —— 组合里有一个要 64K，就必须能撑 64K
/// - **速度门槛**：取最高 —— 组合里有一个要 28 tok/s，就按 28 筛
/// - **中文门槛**：任一任务以中文为主，即视为中文任务
///
/// 为什么门槛必须"取最严"：若取平均，"写论文 + 看图表"会被一个两样都不行的
/// 中庸模型夺冠；取最严则保证组合里最硬的那个需求先被满足。
struct TaskBlend {
    var tasks: [WorkTask]

    static func single(_ t: WorkTask) -> TaskBlend { TaskBlend(tasks: [t]) }

    static let dimLabels = ["中文", "写作", "代码", "数理", "指令", "视觉", "长文"]

    var isEmpty: Bool { tasks.isEmpty }

    /// 七维归一化权重，顺序同 `Capability.vector`
    var weights: [Double] {
        var acc = [Double](repeating: 0, count: 7)
        guard !tasks.isEmpty else { return acc }
        for t in tasks {
            let raw = t.rawWeights
            let s = raw.reduce(0, +)
            guard s > 0 else { continue }
            for i in 0..<7 { acc[i] += raw[i] / s }
        }
        let n = Double(tasks.count)
        for i in 0..<7 { acc[i] /= n }
        return acc
    }

    var minContext: Int { tasks.map { $0.minContext }.max() ?? 16384 }
    var minTokS: Double { tasks.map { $0.minTokS }.max() ?? 0 }
    var chineseHeavy: Bool { tasks.contains { $0.chineseHeavy } }
    var needsVision: Bool { tasks.contains { $0.needsVision } }

    /// 门槛是被哪个任务抬上去的 —— 多选时告诉用户"是它定的调"
    var contextSource: WorkTask? { tasks.max { $0.minContext < $1.minContext } }
    var speedSource: WorkTask? { tasks.max { $0.minTokS < $1.minTokS } }

    var label: String {
        tasks.isEmpty ? "未选任务" : tasks.map { $0.rawValue }.joined(separator: " + ")
    }

    /// 权重最高的前 n 个维度，用于解释"为什么换了模型"
    func topDimensions(_ n: Int) -> [(String, Double)] {
        let w = weights
        let pairs = (0..<min(7, w.count)).map { (TaskBlend.dimLabels[$0], w[$0]) }
        return pairs.sorted { $0.1 > $1.1 }.prefix(n).filter { $0.1 > 0 }
            .map { ($0.0, $0.1) }
    }
}

/// 各道门槛的淘汰计数，用于解释"为什么没有结果"
///
/// 账目规则：`cut*` 记录的是**这道门槛本会砍掉多少**，与是否放宽无关；
/// `relaxed*` 说明该门槛砍光后是否被自动退回。因此
/// `total - cutCapacity - cutContext - cutSpeed - cutChinese` 只在没被放宽时等于 `passed`。
struct GateReport {
    var total = 0
    /// 模态门槛（"必须看图"）淘汰数；只有图表类任务会用到
    var cutModality = 0
    var cutCapacity = 0
    var cutContext = 0
    var cutSpeed = 0
    var cutChinese = 0
    var passed = 0
    var relaxedSpeed = false
    var relaxedChinese = false

    /// 一行可核对的账；放宽的门槛显式标「已放宽」
    var accounting: String {
        "候选 \(total) → 模态 -\(cutModality) → 容量 -\(cutCapacity) → 上下文 -\(cutContext) → 速度 -\(cutSpeed)"
            + (relaxedSpeed ? "(已放宽)" : "")
            + " → 中文 -\(cutChinese)" + (relaxedChinese ? "(已放宽)" : "")
            + " → 通过 \(passed)"
    }

    var warnings: [String] {
        var v: [String] = []
        if relaxedSpeed {
            v.append("速度门槛把所有 \(cutSpeed) 个候选都砍光了，已自动放宽——本机跑这些模型会偏慢")
        }
        if relaxedChinese {
            v.append("中文门槛把所有 \(cutChinese) 个候选都砍光了，已自动放宽——中文表现可能不达标")
        }
        return v
    }
}

// MARK: - 任务加权匹配

extension Advisor {
    /// 七维加权平均（1–5）
    func capabilityScore(_ m: LocalModel, _ b: TaskBlend) -> Double {
        let c = CapabilityModel.of(m).vector
        let w = b.weights
        let sum = w.reduce(0, +)
        guard sum > 0 else { return 0 }
        return zip(c, w).map { $0 * $1 }.reduce(0, +) / sum
    }

    /// 家族修正：code-tuned 模型文字偏干，写作类任务降权；编码类任务升权。
    /// 多选时按各任务取均值，避免"只要选了编码，写作就被整体腰斩"。
    func familyFactor(_ m: LocalModel, _ b: TaskBlend) -> Double {
        guard !b.isEmpty else { return 1.0 }
        let n = m.name.lowercased()
        let coder = n.contains("coder") || n.contains("devstral")
        var acc = 0.0
        for t in b.tasks {
            switch t {
            case .coding, .debugging, .affect: acc += coder ? 1.06 : 0.96
            case .paper, .teaching, .daily, .peerReview, .summarize, .translation:
                acc += coder ? 0.88 : 1.0
            default: acc += 1.0
            }
        }
        return acc / Double(b.tasks.count)
    }

    /// 能力为主，速度达门槛两倍即不再加分（避免"越大越好"）
    func taskScore(_ m: LocalModel, _ b: TaskBlend) -> Double {
        let cap = capabilityScore(m, b)
        let speedOk = min(1.0, estTokS(m) / max(1.0, b.minTokS * 2.0))
        return cap * (0.88 + 0.12 * speedOk) * familyFactor(m, b)
    }

    /// 任务级候选池：只有"必须看图"的任务才按模态收窄
    private func poolFor(_ b: TaskBlend, _ rep: inout GateReport) -> [LocalModel] {
        let base = Catalog.all.filter { $0.cat.chattable }
        rep.total = base.count
        let pool = b.needsVision ? base.filter { CapabilityModel.of($0).vision > 1.5 } : base
        rep.cutModality = base.count - pool.count
        return pool
    }

    /// 任务级候选：硬门槛（容量 → 上下文 → 速度 → 中文）后按能力加权排序
    func taskMatchesWithReport(_ b: TaskBlend, limit: Int = 4) -> ([Advice], GateReport) {
        var rep = GateReport()
        let pool = poolFor(b, &rep)

        var cur = pool.filter { level($0) != .tooHeavy }
        rep.cutCapacity = pool.count - cur.count

        let afterCtx = cur.filter { maxContext($0) >= b.minContext }
        rep.cutContext = cur.count - afterCtx.count
        cur = afterCtx

        let afterSpeed = cur.filter { estTokS($0) >= b.minTokS }
        rep.cutSpeed = cur.count - afterSpeed.count
        // 速度门槛若把候选全砍光就退回上一级，否则用户永远拿不到结果
        if afterSpeed.isEmpty && !cur.isEmpty { rep.relaxedSpeed = true } else { cur = afterSpeed }

        if b.chineseHeavy {
            let afterZh = cur.filter { CapabilityModel.of($0).zh >= 4.0 }
            rep.cutChinese = cur.count - afterZh.count
            if afterZh.isEmpty && !cur.isEmpty { rep.relaxedChinese = true } else { cur = afterZh }
        }

        rep.passed = cur.count
        let sorted = cur.sorted { taskScore($0, b) > taskScore($1, b) }
        return (sorted.prefix(limit).map { advice($0) }, rep)
    }

    func taskMatches(_ b: TaskBlend, limit: Int = 4) -> [Advice] {
        taskMatchesWithReport(b, limit: limit).0
    }

    /// 给结论配一句可核对的话
    func taskReason(_ b: TaskBlend, _ a: Advice) -> String {
        let c = CapabilityModel.of(a.model)
        var s = String(format: "能力加权 %.2f/5（中文 %.1f · 写作 %.1f · 代码 %.1f · 数理 %.1f · 指令 %.1f）",
                       capabilityScore(a.model, b), c.zh, c.writing, c.code, c.math, c.follow)
        if let real = benchmarks[a.model.name] {
            s += String(format: "；需 %.1f GB，占预算 %.0f%%；实测 %.1f tok/s", a.needGB, a.ratio * 100, real)
        } else {
            s += String(format: "；需 %.1f GB，占预算 %.0f%%；估算 %.0f tok/s", a.needGB, a.ratio * 100, a.estTokS)
        }
        let mc = maxContext(a.model)
        if mc > 0 { s += "；可开至 \(mc / 1024)K" }
        return s
    }

    // 单选便捷入口（旧调用点保持可用）
    func capabilityScore(_ m: LocalModel, _ t: WorkTask) -> Double { capabilityScore(m, .single(t)) }
    func taskScore(_ m: LocalModel, _ t: WorkTask) -> Double { taskScore(m, .single(t)) }
    func familyFactor(_ m: LocalModel, _ t: WorkTask) -> Double { familyFactor(m, .single(t)) }
    func taskMatches(_ t: WorkTask, limit: Int = 4) -> [Advice] { taskMatches(.single(t), limit: limit) }
    func taskReason(_ t: WorkTask, _ a: Advice) -> String { taskReason(.single(t), a) }
}
