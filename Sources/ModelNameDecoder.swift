import Foundation

// MARK: - 模型名术语解读器
// 把模型名 / 文件名里那一串规格编码（参数量、量化方法、量化精度、能力后缀、格式…）
// 拆解成「术语 token + 中文解释」，让用户看得懂每个词到底代表什么。

/// 术语的类别，用于分组展示与着色。
enum TermKind: String {
    case family     = "基座"       // Qwen / Llama / DeepSeek 等
    case params     = "参数量"     // 8B / 70B / 0.5B
    case quant      = "量化方法"   // GGUF / AWQ / GPTQ / GSQ / RCO
    case precision  = "量化精度"   // Q4_K_M / Q5 / Q8 / FP16 / BF16
    case capability = "能力"       // Instruct / Chat / VL / Coder / Embed
    case format     = "文件格式"   // .gguf / .safetensors / .bin
    case other      = "其他"       // Flash / Next 等营销后缀
}

/// 一个被识别出的术语片段及其解释。
struct TermToken: Identifiable {
    let text: String          // 名字里出现的原文（如 "Q4_K_M"）
    let explain: String       // 中文解释
    let kind: TermKind
    var id: String { text }
}

/// 术语词典条目。
struct TermEntry: Identifiable {
    let keyword: String       // 匹配关键词（小写）
    let label: String         // 展示标签
    let explain: String       // 中文解释
    let kind: TermKind
    var id: String { keyword }
}

/// 模型名解读器：纯函数，无状态，供 UI 多处复用。
enum ModelNameDecoder {

    // MARK: - 术语词典

    /// 量化方法类术语（决定「能不能直接导入 Ollama」「要不要 GPU」）。
    static let quantTerms: [TermEntry] = [
        .init(keyword: "gguf",      label: "GGUF",  explain: "llama.cpp 的模型文件格式，Ollama 唯一可直接导入的格式，本应用默认只下载它。", kind: .quant),
        .init(keyword: "awq",       label: "AWQ",   explain: "一种 4-bit 量化方法，用「激活感知」保留重要权重，精度损失小、推理快，需对应推理框架。", kind: .quant),
        .init(keyword: "gptq",      label: "GPTQ",  explain: "一种 4-bit 量化方法，主要面向 GPU 加速，精度高但非 GGUF 时不能直接给 Ollama 用。", kind: .quant),
        .init(keyword: "gsq",       label: "GSQ",   explain: "「分组/自定义量化」类方案（Grouped/Generalized 缩放量化）的缩写，多为社区或厂商自定义压缩，具体含义看发布说明。", kind: .quant),
        .init(keyword: "rco",       label: "RCO",   explain: "「re-cut / re-quantize」类二次重打包标记，表示该文件是社区对原权重再次切割/再量化后的产物。", kind: .quant),
        .init(keyword: "q4",        label: "Q4",    explain: "4-bit 量化：每个权重用约 4 位存，体积≈FP16 的 1/4，最常见、性价比高。", kind: .precision),
        .init(keyword: "q5",        label: "Q5",    explain: "5-bit 量化：精度略高于 Q4，体积略大，质量与体积的折中。", kind: .precision),
        .init(keyword: "q6",        label: "Q6",    explain: "6-bit 量化：接近 Q8 的精度，体积更小，较高精度选择。", kind: .precision),
        .init(keyword: "q8",        label: "Q8",    explain: "8-bit 量化：精度高、几乎无损，体积≈FP16 的一半。", kind: .precision),
        .init(keyword: "fp16",      label: "FP16",  explain: "16 位浮点全精度（半精度），体积大但质量最高，通常做原始权重。", kind: .precision),
        .init(keyword: "bf16",      label: "BF16",  explain: "Brain Float 16，另一种 16 位浮点格式，数值范围同 FP32、精度略低，训练/推理常用。", kind: .precision),
        .init(keyword: "fp8",       label: "FP8",   explain: "8 位浮点量化，新硬件（H100 等）加速，精度优于整数 8-bit。", kind: .precision),
        .init(keyword: "k_m",       label: "K_M",   explain: "llama.cpp 量化命名后缀：K=采用 K-quant 混合精度，M=中等，比纯 Q4 保留更多重要层。", kind: .precision),
        .init(keyword: "k_s",       label: "K_S",   explain: "llama.cpp K-quant 的「小」档，体积更小、速度更快、质量略降。", kind: .precision),
        .init(keyword: "k_l",       label: "K_L",   explain: "llama.cpp K-quant 的「大」档，质量最高、体积最大。", kind: .precision),
    ]

    /// 能力后缀（决定「能做什么」）。
    static let capabilityTerms: [TermEntry] = [
        .init(keyword: "instruct",  label: "Instruct", explain: "经过「指令微调」的版本，能听懂人类指令、对话问答；这是给聊天/助手用的，也是 Ollama 常用形态。", kind: .capability),
        .init(keyword: "chat",      label: "Chat",     explain: "面向对话优化的版本，训练时加了多轮对话数据。", kind: .capability),
        .init(keyword: "-vl",       label: "VL",       explain: "Vision-Language：视觉-语言多模态，能看图（图片理解/OCR）。", kind: .capability),
        .init(keyword: "vision",    label: "Vision",   explain: "视觉能力，支持图像输入。", kind: .capability),
        .init(keyword: "coder",     label: "Coder",    explain: "代码专用版，在编程/代码生成任务上强化。", kind: .capability),
        .init(keyword: "code",      label: "Code",     explain: "代码能力变体。", kind: .capability),
        .init(keyword: "embed",     label: "Embed",    explain: "文本嵌入模型：把文本转成向量，用于检索/语义搜索，不能对话。", kind: .capability),
        .init(keyword: "reasoning", label: "Reasoning",explain: "推理增强：回答前先内部推理（思维链），数学/逻辑更强但更慢。", kind: .capability),
        .init(keyword: "r1",        label: "R1",       explain: "DeepSeek 的推理系列代号，带深度思考能力。", kind: .capability),
        .init(keyword: "moE",       label: "MoE",      explain: "混合专家架构：参数量大但每次只激活一部分，速度与能力兼顾。", kind: .capability),
        .init(keyword: "base",      label: "Base",     explain: "预训练基座（未做指令/对话微调），不能直接对话，需下游微调。", kind: .capability),
        .init(keyword: "next",      label: "Next",     explain: "「下一代」迭代代号，厂商对新一代版本的命名（如 Qwen3-Next）。", kind: .other),
        .init(keyword: "flash",     label: "Flash",    explain: "「轻量速度版」：面向快速响应、低延迟的变体，通常参数量更小。", kind: .other),
    ]

    /// 全部术语（用于完整词典弹层）。
    static var allTerms: [TermEntry] { quantTerms + capabilityTerms }

    // MARK: - 名字解析

    /// 从模型名里识别出所有术语 token（按出现顺序，去重）。
    static func decode(_ name: String) -> [TermToken] {
        let low = name.lowercased()
        var seen = Set<String>()
        var tokens: [TermToken] = []

        for e in allTerms {
            if low.contains(e.keyword), !seen.contains(e.keyword) {
                seen.insert(e.keyword)
                tokens.append(.init(text: e.label, explain: e.explain, kind: e.kind))
            }
        }

        // 参数量（如 8b / 70b / 0.5b / 1.5b / 32b / 405b）
        if let (text, explain) = decodeParams(low) {
            tokens.insert(.init(text: text, explain: explain, kind: .params), at: 0)
        }

        // 按类别稳定排序：基座/参数 → 能力 → 量化方法 → 精度 → 格式
        let order: [TermKind] = [.params, .capability, .quant, .precision, .format, .other, .family]
        tokens.sort { a, b in
            let ia = order.firstIndex(of: a.kind) ?? 99
            let ib = order.firstIndex(of: b.kind) ?? 99
            return ia < ib
        }
        return tokens
    }

    /// 解析参数量，返回（展示文本, 解释）。
    private static func decodeParams(_ low: String) -> (String, String)? {
        // 匹配 "数字 + 可选小数 + b"（如 8b、1.5b、70b、0.5b），注意别误伤 "bge" 这类
        let pattern = #"(?<![a-z])(\d+(?:\.\d+)?)b(?![a-z])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(low.startIndex..., in: low)
        guard let m = regex.firstMatch(in: low, range: range),
              let r = Range(m.range(at: 1), in: low) else { return nil }
        let val = String(low[r])
        let n = Double(val) ?? 0
        let bn: String
        if n >= 100 { bn = String(format: "%.0f", n) }
        else { bn = val }
        // 参数量 → 内存估算（Q4 约 0.55×，这里给个通用区间提示）
        return ("\(bn)B 参数", "约 \(bn)0 亿参数的规模，越大越聪明但越吃内存。")
    }

    /// 生成一行「可读规格」摘要，例如「8B 参数 · 指令对话 · Q4 量化」。
    static func readableSummary(_ name: String) -> String {
        let tokens = decode(name)
        guard !tokens.isEmpty else { return "" }
        var parts: [String] = []
        for t in tokens where t.kind != .other && t.kind != .family && t.kind != .format {
            parts.append(t.text)
        }
        return parts.prefix(4).joined(separator: " · ")
    }

    /// 量化精度 → 体积估算系数（相对 FP16）。用于「约 N GB」提示。
    static func sizeFactor(_ name: String) -> Double? {
        let low = name.lowercased()
        if low.contains("fp16") || low.contains("bf16") { return 2.0 }
        if low.contains("fp8") || low.contains("q8") { return 1.0 }
        if low.contains("q6") { return 0.75 }
        if low.contains("q5") { return 0.63 }
        if low.contains("q4") { return 0.55 }
        return nil
    }

    /// 从名字里提取参数量（单位：十亿，即 8B → 8.0）。供筛选、排序、内存预估复用。
    static func paramsB(_ name: String) -> Double? {
        let low = name.lowercased()
        let pattern = #"(?<![a-z])(\d+(?:\.\d+)?)b(?![a-z])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(low.startIndex..., in: low)
        guard let m = regex.firstMatch(in: low, range: range),
              let r = Range(m.range(at: 1), in: low),
              let v = Double(low[r]), v > 0 else { return nil }
        return v
    }

    /// 估算模型体积（GB）。公式：参数量(B) × 精度系数；系数缺失时按 FP16 算。
    /// 例：Qwen3-8B-Instruct-Q4_K_M → 8 × 0.55 ≈ 4.4 GB；8B-FP16 → 16 GB。
    static func estimateGB(_ name: String) -> Double? {
        guard let p = paramsB(name) else { return nil }
        let factor = sizeFactor(name) ?? 2.0
        return p * factor
    }

    /// 体积 → 人话文案，如「约 4.4 GB」。
    static func estimateText(_ name: String) -> String? {
        guard let gb = estimateGB(name) else { return nil }
        if gb >= 1 { return String(format: "约 %.1f GB", gb) }
        return String(format: "约 %.0f MB", gb * 1024)
    }

    /// 提取「模型基座名」：去掉量化方法/精度/格式后缀，用于把同一模型的多个量化版本聚合成一组。
    /// 例：Qwen3-8B-Instruct-Q4_K_M.gguf → qwen3-8b-instruct
    ///      llama-3.1-8b-instruct-q8_0.gguf → llama-3.1-8b-instruct
    static func baseKey(_ name: String) -> String {
        var low = name.lowercased()
        // 去扩展名
        for ext in [".gguf", ".safetensors", ".bin", ".pt", ".pth", ".mmproj"] {
            if low.hasSuffix(ext) { low = String(low.dropLast(ext.count)) }
        }
        // 去量化/精度/格式后缀标记（出现在名字靠后的位置）
        // 覆盖：-q4_k_m / -q5_0 / -q8_0 / -q4 / -fp16 / -bf16 / -awq / -gptq / -gsq / -rco / -gguf 等
        let suffixes = [
            "-q4_k_m", "-q5_k_m", "-q6_k", "-q8_0", "-q4_k_s", "-q5_k_s",
            "-q4_0", "-q5_0", "-q6_k", "-q8_0", "-q4", "-q5", "-q6", "-q8",
            "-fp16", "-bf16", "-fp8", "-f16", "-f32",
            "-awq", "-gptq", "-gsq", "-rco", "-gguf", "-iq4_xs", "-iq3_xxs",
            "-q3_k_m", "-q3_k_s", "-q2_k", "-q3", "-q2",
        ]
        for s in suffixes {
            if low.hasSuffix(s) { low = String(low.dropLast(s.count)); break }
        }
        return low
    }

    /// 量化精度 → 质量等级（用于「推荐版本」排序，值越小越推荐）。
    /// 推荐优先级：Q4_K_M ≈ Q5_K_M > Q6 > Q8 > Q5 > Q4 > FP16 > 过度压缩。
    static func qualityRank(_ name: String) -> Int {
        let low = name.lowercased()
        if low.contains("q4_k_m") || low.contains("q5_k_m") { return 0 } // 均衡首选
        if low.contains("q6_k") { return 1 }
        if low.contains("q8") { return 2 }
        if low.contains("q5") { return 3 }
        if low.contains("q4") { return 4 }
        if low.contains("fp16") || low.contains("bf16") { return 5 } // 质量最高但太大
        if low.contains("q3") || low.contains("q2") { return 6 }       // 过度压缩
        return 7
    }

    /// 从一组主模型 gguf 文件里挑出「推荐版本」（同基座里质量等级最优的那个）。
    /// 返回文件名（path 的最后一段）或 nil（没有候选）。
    static func recommendedFileName(_ fileNames: [String]) -> String? {
        // 只考虑主模型 gguf（排除 mmproj 投影器、imatrix 辅助）
        let candidates = fileNames.filter {
            let p = $0.lowercased()
            return p.hasSuffix(".gguf") && !p.contains("mmproj") && !p.contains("imatrix")
        }
        guard !candidates.isEmpty else { return nil }
        // 全局挑质量最优的那个（同基座多版本时，推荐质量与体积最均衡的档）
        let best = candidates.min { a, b in
            let ra = qualityRank(a), rb = qualityRank(b)
            return ra != rb ? ra < rb : a.count < b.count
        }
        return best.map { ($0 as NSString).lastPathComponent }
    }
}
