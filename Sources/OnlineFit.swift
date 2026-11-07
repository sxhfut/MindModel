import Foundation

/// 速度档位：内存装得下 ≠ 用得舒服，必须分开判断。
enum SpeedGrade {
    case fast      // ≥25 tok/s：对话跟手
    case ok        // 12–25：日常可用
    case slow      // 6–12：偏慢，长文/后台还行
    case crawl     // <6：不适合交互

    var label: String {
        switch self {
        case .fast: return "跟手"
        case .ok: return "可用"
        case .slow: return "偏慢"
        case .crawl: return "很慢"
        }
    }

    static func of(_ tps: Double) -> SpeedGrade {
        if tps >= 25 { return .fast }
        if tps >= 12 { return .ok }
        if tps >= 6 { return .slow }
        return .crawl
    }
}

/// 在线模型的本机适配评估结果。
/// 在线搜索结果只有模型名，没有体积/KV 数据，所以规格靠「名字推断 + 内置清单校对」。
struct OnlineFit {
    let paramsB: Double          // 总参数（十亿）
    let activeB: Double          // MoE 激活参数；dense 时等于 paramsB
    let weightGB: Double         // 权重体积（有真实文件大小时用真实值）
    let needGB: Double           // 权重 + KV + 运行时
    let ratio: Double            // need / 本机预算
    let level: FitLevel
    let estTokS: Double
    let maxContextK: Int         // 仍能跑的最大上下文（K），0 表示 4K 都紧张
    let fromCatalog: Bool        // 规格是否命中内置清单（更可信）
    let isEmbedding: Bool        // 嵌入/重排模型，tok/s 无意义
    let exactWeight: Bool        // 权重体积是否来自真实文件大小
    let shards: Int              // 分片数（>1 表示已按总片数合并估算）

    var speed: SpeedGrade { SpeedGrade.of(estTokS) }

    /// 只拿到体积、没拿到参数量：内存档位能判，速度判不了。
    /// （paramsB 为 0 是「未知」的哨兵值，不是真的 0B 模型）
    var specUnknown: Bool { paramsB <= 0 }

    /// 是否值得展示速度估算：嵌入模型没有生成长度，超预算模型根本跑不起来，
    /// 参数量未知时也没有速度可算。
    var showSpeed: Bool { !isEmbedding && level != .tooHeavy && !specUnknown }

    /// 一行可直接展示的规格说明。
    var summary: String {
        var s = String(format: "需 %.1f GB，占预算 %.0f%%", needGB, ratio * 100)
        if isEmbedding {
            s += "；嵌入模型，不做 tok/s 估算"
        } else if level == .tooHeavy {
            s += "；超出本机内存，不做速度估算"
        } else if specUnknown {
            s += "；速度无法估算（只知道文件体积，不知道参数量）"
        } else {
            s += String(format: "；估算 %.0f tok/s（%@）", estTokS, speed.label)
        }
        if maxContextK > 0 { s += "；可开 \(maxContextK)K 上下文" }
        if shards > 1 { s += "；\(shards) 个分片合计" }
        return s
    }

    /// 一句人话结论：内存档位 + 速度体验，两者分开说，避免「装得下」被误读成「用着爽」。
    var verdict: String {
        let mem: String
        switch level {
        case .plenty: mem = "内存余量充足"
        case .smooth: mem = "内存够用"
        case .ok:     mem = "内存勉强够，建议上下文不超过 \(maxContextK)K"
        case .tight:  mem = "内存偏紧，需降上下文或换更小量化"
        case .tooHeavy: return "超出本机可用内存，本地跑不动"
        }
        if isEmbedding { return mem + "；嵌入模型，速度取决于批量而非生成长度" }
        if specUnknown { return mem + "；速度没法给——只知道文件体积，不知道参数量，分不清 dense 还是 MoE" }
        let speedPart: String
        switch speed {
        case .fast:  speedPart = String(format: "约 %.0f tok/s，对话跟手", estTokS)
        case .ok:    speedPart = String(format: "约 %.0f tok/s，日常可用", estTokS)
        case .slow:  speedPart = String(format: "约 %.0f tok/s，偏慢，适合长文批处理", estTokS)
        case .crawl: speedPart = String(format: "约 %.0f tok/s，太慢，不适合交互使用", estTokS)
        }
        return mem + "；" + speedPart
    }

    /// 是否「装得下但慢到不实用」——UI 上用警示色区分。
    var slowButFits: Bool {
        !isEmbedding && !specUnknown && level != .tooHeavy
            && (speed == .slow || speed == .crawl)
    }
}

/// 在线模型适配评估引擎。纯函数，无状态。
enum OnlineFitEngine {

    /// 评估上下文默认使用调用方传入（通常是应用的 contextTokens）。
    static let ctxOptions = [4096, 8192, 16384, 32768, 65536, 131072]

    /// decode 效率系数（相对实测内存带宽）。
    ///
    /// dense 模型：每生成 1 个 token 要把全部权重从内存过一遍，基本是纯带宽受限，
    /// 实测流式读取能超过 memcpy 测出的总流量（少了写分配开销），故取 >1。
    /// MoE：只读激活专家，但每 token 还要做专家路由 / gather / 跨核同步，
    /// 这些固定开销把效率压掉一大截，故取小得多的值。
    ///
    /// 两个系数按 Apple Silicon + llama.cpp 的公开实测反推：
    /// 32B Q4（20GB）在 ~300GB/s 级机器约 18 tok/s → 20.25×18÷300 ≈ 1.2；
    /// gpt-oss 120B（激活 2.97GB/token）约 30 tok/s → 2.97×30÷300 ≈ 0.30。
    static func efficiency(dense: Bool) -> Double {
        dense ? 1.15 : 0.32
    }

    /// 从名字取 MoE 激活参数：30B-A3B / 120B-A12B / A22B 等。
    static func activeParamsB(_ name: String) -> Double? {
        let low = name.lowercased()
        let pattern = #"a(\d+(?:\.\d+)?)b"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(low.startIndex..., in: low)
        guard let m = re.firstMatch(in: low, range: range),
              let r = Range(m.range(at: 1), in: low),
              let v = Double(low[r]), v > 0 else { return nil }
        return v
    }

    /// 家族关键词（按特异性从长到短，先命中先用）
    private static let families = [
        "qwen3-coder", "qwen3-vl", "qwen2.5-vl", "qwen2.5-coder", "qwen3", "qwen2.5",
        "llama-3.3", "llama3.3", "llama-3.2", "llama3.2", "llama-3.1", "llama3.1", "llama4", "llama",
        "gemma4", "gemma3", "gemma", "deepseek-r1", "deepseek", "phi-4", "phi",
        "mistral", "mixtral", "glm-4", "glm", "internvl", "minicpm", "pixtral", "molmo",
        "granite", "nemotron", "devstral", "ernie", "gpt-oss", "seed-oss", "olmo", "smollm",
    ]

    /// 在内置清单里找最接近的同家族条目，用来校准体积与 KV（清单是实测/权威估算值）。
    static func catalogMatch(name: String, paramsB: Double) -> LocalModel? {
        let low = name.lowercased()
        guard let fam = families.first(where: { low.contains($0) }) else { return nil }
        let cands = Catalog.all.filter { $0.name.lowercased().contains(fam) }
        guard !cands.isEmpty else { return nil }
        guard let best = cands.min(by: { abs($0.paramsB - paramsB) < abs($1.paramsB - paramsB) }) else { return nil }
        // 参数量差超过 20% 视为清单外（宁可退回公式估算，也不要错配一个不相干的规格）
        return abs(best.paramsB - paramsB) / max(1, paramsB) < 0.20 ? best : nil
    }

    /// 无清单可校对时，按参数量分档估 KV cache（GB / 1K token，f16）。
    /// 分档值取自内置清单里各量级的典型值。
    static func kv1kEstimate(_ paramsB: Double) -> Double {
        switch paramsB {
        case ..<2:   return 0.03
        case ..<4:   return 0.06
        case ..<9:   return 0.13
        case ..<15:  return 0.16
        case ..<35:  return 0.20
        case ..<85:  return 0.25
        default:     return 0.30
        }
    }

    /// 从名字推断权重体积（GB）。优先清单校对，否则按 Q4_K_M ≈ 0.55×参数量。
    static func weightEstimate(name: String, paramsB: Double) -> (gb: Double, kv: Double, fromCatalog: Bool) {
        if let m = catalogMatch(name: name, paramsB: paramsB) {
            return (m.q4GB, m.kv1k, true)
        }
        // 名字里明确写了 FP16/BF16 时按全精度算，否则按 Q4 估
        let low = name.lowercased()
        let factor: Double
        if low.contains("fp16") || low.contains("bf16") || low.contains("f16") || low.contains("f32") {
            factor = 2.0
        } else if low.contains("q8") {
            factor = 1.0
        } else if low.contains("q6") {
            factor = 0.75
        } else if low.contains("q5") {
            factor = 0.63
        } else {
            factor = 0.55
        }
        return (paramsB * factor, kv1kEstimate(paramsB), false)
    }

    /// 用本机已有实测记录校准公式系数（纯公式的 0.45 是保守猜测，
    /// 实测/公式的中位数比值能把系统性偏差吸收掉）。
    static func calibration(benchmarks: [String: Double], bandwidth: Double) -> Double {
        guard benchmarks.count >= 2 else { return 1.0 }
        let bw = bandwidth > 1 ? bandwidth : 400.0
        var ratios: [Double] = []
        for (tag, real) in benchmarks {
            guard real > 1 else { continue }
            guard let p = ModelNameDecoder.paramsB(tag) else { continue }
            // 从 tag 找同家族清单条目拿 q4GB
            guard let m = catalogMatch(name: tag, paramsB: p), m.q4GB > 0.1 else { continue }
            let share = min(1.0, max(0.02, m.activeB / max(1.0, m.paramsB)))
            let bytesPerToken = m.q4GB * share + 0.25
            let raw = bw * 0.45 / max(0.3, bytesPerToken)
            guard raw > 1 else { continue }
            ratios.append(real / raw)
        }
        guard ratios.count >= 2 else { return 1.0 }
        ratios.sort()
        let med = ratios[ratios.count / 2]
        // 夹在合理区间，避免个别异常实测把全局估算带飞
        return min(1.6, max(0.55, med))
    }

    /// 分片文件的归属键：去掉 `-00001-of-00004` 这段，得到同一模型的公共前缀。
    static func shardKey(_ name: String) -> String {
        guard let info = ModelNameDecoder.shardInfo(name) else { return name }
        _ = info
        let pattern = #"[.-]\d{3,5}-of-\d{3,5}"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return name }
        return re.stringByReplacingMatches(in: name, range: NSRange(name.startIndex..., in: name), withTemplate: "")
    }

    /// 求某个文件所属模型的**整体权重体积**（GB）。
    /// 分片模型必须把同一组的各片实际体积相加——各片并不等大（末片通常明显小），
    /// 用「单片 × 片数」会算错。拿不到同伴时退回「单片 × 片数」的粗估。
    static func totalWeightGB(_ path: String, siblings: [(path: String, sizeGB: Double)]) -> Double? {
        let selfSize = siblings.first(where: { $0.path == path })?.sizeGB
        guard let info = ModelNameDecoder.shardInfo(path) else { return selfSize }

        let key = shardKey(path)
        let sameGroup = siblings.filter { shardKey($0.path) == key }
        if sameGroup.count >= info.total {
            return sameGroup.reduce(0) { $0 + $1.sizeGB }
        }
        // 同伴不全（列表被筛过/未加载完）：按已见片数的平均值外推
        if !sameGroup.isEmpty {
            let avg = sameGroup.reduce(0) { $0 + $1.sizeGB } / Double(sameGroup.count)
            return avg * Double(info.total)
        }
        return selfSize.map { $0 * Double(info.total) }
    }

    /// 嵌入 / 重排模型判定：这类模型不产 token，tok/s 无意义。
    static func isEmbeddingModel(_ name: String) -> Bool {
        let low = name.lowercased()
        return low.contains("embed") || low.contains("bge") || low.contains("rerank")
            || low.contains("gte-") || low.contains("e5")
    }

    /// 参数量拿不到、但有真实文件体积时的**部分评估**：内存能不能装下能算，
    /// 速度与上下文算不了（KV cache 取决于层数/头数，两者都无从得知）。
    ///
    /// 返回 nil 只在「体积也没有」时发生——那种情况调用方应显示「无法估算」。
    static func volumeOnlyFit(name: String, weightGB: Double?, budgetGB: Double) -> OnlineFit? {
        guard let w = weightGB, w > 0.05 else { return nil }
        let need = w + 1.6                     // 权重 + 运行时，不含 KV（未知）
        let budget = max(1.0, budgetGB)
        let ratio = need / budget
        return OnlineFit(paramsB: 0,
                         activeB: 0,
                         weightGB: w,
                         needGB: need,
                         ratio: ratio,
                         level: levelFor(ratio),
                         estTokS: 0,
                         maxContextK: 0,
                         fromCatalog: false,
                         isEmbedding: isEmbeddingModel(name),
                         exactWeight: true,
                         shards: ModelNameDecoder.shardInfo(name)?.total ?? 1)
    }

    /// 主入口：评估一个在线模型在本机的适配度与性能。
    /// - Parameters:
    ///   - weightGB: 模型的**整体**权重体积（分片应已合并）；nil 表示按名字推断
    static func evaluate(name: String,
                         weightGB: Double? = nil,
                         budgetGB: Double,
                         bandwidth: Double,
                         context: Int,
                         benchmarks: [String: Double] = [:]) -> OnlineFit? {
        guard let paramsB = ModelNameDecoder.paramsB(name), paramsB > 0 else {
            // 名字里没有参数量（Kimi-K2、MiniMax-M2、DeepSeek-V3.2 这类命名）：
            // 有真实文件体积就退化成「只能判内存」的部分评估，连体积也没有才算无法估算。
            return volumeOnlyFit(name: name, weightGB: weightGB, budgetGB: budgetGB)
        }

        let est = weightEstimate(name: name, paramsB: paramsB)
        let matched = catalogMatch(name: name, paramsB: paramsB)

        // 激活参数量：名字里显式写了 A3B/A12B 就用它；否则借内置清单的已知稀疏度
        // （如 gpt-oss-120b 名字里没有 A5B，但清单知道它只激活约 5B——
        //  否则会被当成 dense 120B，速度估算差一个数量级）
        let activeB: Double
        if let a = activeParamsB(name) {
            activeB = a
        } else if let m = matched, m.activeB < m.paramsB * 0.95 {
            activeB = m.activeB
        } else {
            activeB = paramsB
        }

        let shards = ModelNameDecoder.shardInfo(name)?.total ?? 1
        let wGB: Double
        let kv1k: Double
        let exact: Bool
        if let real = weightGB, real > 0.05 {
            wGB = real          // 调用方已保证是整体体积（分片已合并）
            kv1k = est.kv
            exact = true
        } else {
            wGB = est.gb
            kv1k = est.kv
            exact = false
        }

        let ctxGB = kv1k * (Double(context) / 1024.0)
        let need = wGB + ctxGB + 1.6            // 权重 + KV + 运行时开销
        let budget = max(1.0, budgetGB)
        let ratio = need / budget
        let level = levelFor(ratio)

        let isEmbedding = isEmbeddingModel(name)

        // tok/s ≈ 带宽 × 效率 ÷ 每 token 需读字节数；MoE 只读激活专家
        let share = min(1.0, max(0.02, activeB / max(1.0, paramsB)))
        let bytesPerToken = wGB * share + 0.25
        let bw = bandwidth > 1 ? bandwidth : 400.0
        let cal = calibration(benchmarks: benchmarks, bandwidth: bandwidth)
        let dense = activeB >= paramsB * 0.95
        let tps = min(260.0, max(0.4, bw * efficiency(dense: dense) / max(0.3, bytesPerToken) * cal))

        // 仍能跑（占比 ≤92%）的最大上下文
        var maxCtx = 0
        for c in ctxOptions {
            let g = wGB + kv1k * (Double(c) / 1024.0) + 1.6
            if g / budget <= 0.92 { maxCtx = c }
        }

        return OnlineFit(paramsB: paramsB,
                         activeB: activeB,
                         weightGB: wGB,
                         needGB: need,
                         ratio: ratio,
                         level: level,
                         estTokS: isEmbedding ? 0 : tps,
                         maxContextK: maxCtx / 1024,
                         fromCatalog: est.fromCatalog,
                         isEmbedding: isEmbedding,
                         exactWeight: exact,
                         shards: shards)
    }

    /// 与 Advisor 完全一致的档位阈值，保证在线/离线判定口径统一。
    static func levelFor(_ ratio: Double) -> FitLevel {
        if ratio <= 0.40 { return .plenty }
        if ratio <= 0.72 { return .smooth }
        if ratio <= 0.92 { return .ok }
        if ratio <= 1.15 { return .tight }
        return .tooHeavy
    }
}
