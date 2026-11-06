import Foundation

// MARK: - 模型分类

enum ModelCategory: String, CaseIterable, Identifiable {
    case chat = "通用对话"
    case code = "代码"
    case reason = "推理"
    case vision = "多模态理解"
    case agent = "Agent"
    case light = "轻量常驻"
    case image = "图像生成"
    case speech = "语音"
    case embed = "向量/嵌入"
    case rerank = "重排"
    var id: String { rawValue }

    /// 能不能当对话模型用。生成图、语音、向量、重排都是另一类模型，
    /// 混进对话推荐里会把它们排到"首选"——这是个真实的排序错误，不只是显示问题。
    var chattable: Bool {
        switch self {
        case .chat, .code, .reason, .vision, .agent, .light: return true
        case .image, .speech, .embed, .rerank: return false
        }
    }
}

struct LocalModel: Identifiable {
    var id: String { name }
    let name: String
    let paramsB: Double        // 总参数（十亿）
    let activeB: Double        // MoE 激活参数；dense 时等于 paramsB
    let q4GB: Double           // Q4_K_M 权重体积
    let cat: ModelCategory
    let tag: String?           // 可信的 ollama tag，nil 表示需走 HF 搜索
    let kv1k: Double           // 每 1K token 的 KV cache（GB, f16），估算
    let note: String
}

enum Catalog {
    static let source = "体积与适配数据取自 localmodel.run 的 Apple M5 Max 128GB 档位（2026-11 快照）；KV cache 为按架构估算。"

    static let all: [LocalModel] = [
        // —— 100B 级 ——
        m("Devstral 2 123B", 123, 73.3, .code, nil, 0.30, "代码最强档，128G 才敢碰"),
        m("Nemotron 3 Super 120B-A12B", 120, 80.3, .agent, nil, 0.18, "MoE，长任务 Agent 专用", active: 12),
        m("gpt-oss 120B", 117, 62.4, .reason, "gpt-oss:120b", 0.18, "MoE 推理型，激活约 5B", active: 5.1),
        m("Llama 4 Scout 109B", 109, 64.2, .vision, "llama4:scout", 0.20, "原生多模态 MoE", active: 17),
        m("GLM-4.5-Air 106B", 106, 71.8, .chat, "glm-4.5-air", 0.20, "中文强，MoE", active: 12),
        m("Qwen2.5 72B", 72, 50.2, .chat, "qwen2.5:72b", 0.25, "中文写作稳妥档"),
        m("Llama 3.3 70B", 70, 45.3, .chat, "llama3.3:70b", 0.25, "通用基准线"),
        // —— 40B–80B ——
        m("Llama-3.3-Nemotron-Super-49B", 49, 30.6, .reason, nil, 0.22, "英伟达蒸馏推理"),
        m("Mixtral 8x7B", 46.7, 28.9, .chat, "mixtral:8x7b", 0.12, "老牌 MoE", active: 12.9),
        m("Qwen3-Coder-Next 80B-A3B", 80, 48.0, .code, nil, 0.12, "代码 Agent，MoE 极快", active: 3),
        m("Flint 40B-A2.5B", 39.8, 25.9, .chat, nil, 0.10, "稀疏 MoE，速度型", active: 2.5),
        m("Seed-OSS 36B", 36, 22.5, .chat, nil, 0.22, "字节开源"),
        // —— 30B 级（本机甜点）——
        m("Qwen3.6 35B-A3B", 36, 24.5, .chat, nil, 0.10, "MoE，中文对话主力", active: 3),
        m("Qwen3 30B-A3B", 30.5, 20.7, .chat, "qwen3:30b-a3b", 0.10, "速度与质量平衡最佳", active: 3),
        m("Qwen3-Coder 30B-A3B", 30.5, 19.4, .code, "qwen3-coder:30b", 0.10, "本地写码首选", active: 3),
        m("Qwen3-VL 30B-A3B", 31.1, 20.4, .vision, nil, 0.10, "看图 + 中文", active: 3),
        m("Gemma 4 31B", 32.7, 20.5, .chat, nil, 0.20, "长文与写作手感好"),
        m("Gemma 4 26B-A4B", 26.5, 19.0, .chat, nil, 0.10, "MoE，响应快", active: 4),
        m("Qwen3 32B", 32, 22.0, .chat, "qwen3:32b", 0.20, "dense，质量稳"),
        m("DeepSeek-R1-Distill-Qwen 32B", 32, 22.1, .reason, "deepseek-r1:32b", 0.20, "思考链，慢但深"),
        m("Qwen2.5 32B", 32, 22.1, .chat, "qwen2.5:32b", 0.20, "中文老将，稳"),
        m("Qwen2.5 Coder 32B", 32, 20.7, .code, "qwen2.5-coder:32b", 0.20, "补全强"),
        m("GLM-4-32B-0414", 32, 20.5, .chat, "glm4:32b", 0.20, "中文长文"),
        m("Muse Glimmer 30B", 30, 18.2, .agent, nil, 0.18, "本地 coding agent 友好"),
        m("Nemotron 3.5 Lightning 30B-A3B", 30, 25.8, .agent, nil, 0.10, "常驻 Agent，工具调用", active: 3),
        m("GLM-4.7-Flash 30B", 30, 19.2, .chat, nil, 0.10, "快，中文", active: 3),
        m("Granite 4.2 30B", 30, 18.6, .chat, "granite4.2:30b", 0.20, "IBM，工程文档强"),
        // —— 20B–28B ——
        m("Qwen3.8 27B", 27.8, 17.3, .chat, nil, 0.20, "最新一代中文"),
        m("Qwen3.6 27B", 27.8, 18.9, .chat, nil, 0.20, "上一代，稳"),
        m("Gemma 3 27B", 27, 18.6, .chat, "gemma3:27b", 0.20, "多语言写作"),
        m("Mistral Small 3.1 24B", 24, 15.4, .chat, "mistral-small3.1", 0.18, "英文最顺"),
        m("Devstral Small 2 24B", 24, 15.4, .code, nil, 0.18, "轻量代码 Agent"),
        m("ERNIE 4.5 21B-A3B", 21, 14.3, .chat, "ernie4.5:21b-a3b", 0.10, "文心，中文语感", active: 3),
        m("gpt-oss 20B", 21, 13.2, .reason, "gpt-oss:20b", 0.10, "轻量推理 MoE", active: 3.6),
        // —— 8B–14B ——
        m("Phi-4 14B", 14, 10.8, .reason, "phi4:14b", 0.16, "数学推理强"),
        m("Qwen3 14B", 14, 10.7, .chat, "qwen3:14b", 0.16, "通用小钢炮"),
        m("Qwen2.5 14B", 14, 10.7, .chat, "qwen2.5:14b", 0.16, "本机已装"),
        m("Qwen2.5 Coder 14B", 14, 10.1, .code, "qwen2.5-coder:14b", 0.16, "补全 + 解释"),
        m("Ministral 3 14B", 14, 9.4, .chat, nil, 0.16, "边缘优化"),
        m("Gemma 4 12B", 12, 8.7, .chat, nil, 0.16, "轻量写作"),
        m("Mistral Nemo 12B", 12.2, 8.6, .chat, "mistral-nemo:12b", 0.16, "128K 上下文"),
        m("Llama 3.2 Vision 11B", 10.7, 9.0, .vision, "llama3.2-vision:11b", 0.16, "看图问答"),
        // —— 7B 以下 ——
        m("Qwen3 8B", 8, 6.5, .chat, "qwen3:8b", 0.13, "日常够用"),
        m("Llama 3.1 8B", 8, 6.4, .chat, "llama3.1:8b", 0.13, "生态最广"),
        m("Qwen2.5-VL 7B", 8.29, 7.1, .vision, "qwen2.5vl:7b", 0.13, "文档/截图理解"),
        m("Qwen2.5 7B", 7, 6.1, .chat, "qwen2.5:7b", 0.13, "最快可用"),
        m("Qwen3 4B", 4, 3.8, .light, "qwen3:4b", 0.06, "后台常驻"),
        m("Gemma 3 4B", 4, 3.8, .light, "gemma3:4b", 0.06, "轻量多语言"),
        m("Phi-4-mini 3.8B", 3.82, 3.8, .light, "phi4-mini", 0.06, "端侧推理"),
        m("Qwen3 1.7B", 1.7, 2.4, .light, "qwen3:1.7b", 0.03, "极速，摘要分类"),
        m("Qwen2.5 1.5B", 1.54, 2.2, .light, "qwen2.5:1.5b", 0.03, "常驻守护"),
        // —— 多模态理解（看图、读文档、读表格）——
        m("Qwen3-VL 235B-A22B", 235, 132, .vision, nil, 0.22, "旗舰视觉，128G 也要留余地", active: 22),
        m("Qwen2.5-VL 72B", 72, 45.0, .vision, nil, 0.25, "开源文档理解最强档之一"),
        m("InternVL3 38B", 38, 23.0, .vision, nil, 0.22, "图表与 OCR 见长"),
        m("Qwen3-VL 32B", 32, 20.0, .vision, nil, 0.20, "视觉 + 中文写作都行"),
        m("Qwen2.5-VL 32B", 32, 20.0, .vision, nil, 0.20, "中文表格、发票、截图"),
        m("InternVL3 14B", 14, 8.8, .vision, nil, 0.16, "视觉性价比档"),
        m("Llama 3.2 Vision 90B", 90, 55.0, .vision, nil, 0.24, "大号看图，中文一般"),
        m("MiniCPM-V 4.5 9B", 9, 5.6, .vision, nil, 0.13, "端侧视觉，响应快"),
        m("Pixtral 12B", 12, 7.4, .vision, nil, 0.16, "Mistral 视觉模型"),
        m("Molmo 7B", 7, 4.8, .vision, nil, 0.13, "指认式视觉问答"),
        m("Qwen2.5-Omni 7B", 7, 5.2, .vision, nil, 0.13, "图像 + 音频输入"),
        // —— 图像生成（要 ComfyUI / stable-diffusion.cpp，Ollama 跑不了）——
        m("FLUX.1-schnell", 12, 7.0, .image, nil, 0.0, "4 步出图，需 ComfyUI 或 sd.cpp"),
        m("FLUX.1-dev", 12, 12.0, .image, nil, 0.0, "质量更好，显存吃得也多"),
        m("Qwen-Image 20B", 20, 12.0, .image, nil, 0.0, "中文文字排版最准"),
        m("SDXL", 3.5, 3.5, .image, nil, 0.0, "生态最全，插件多"),
        m("Wan2.2 T2V A14B", 14, 16.0, .image, nil, 0.0, "文生视频，慢，占空间"),
        // —— 语音（whisper.cpp / faster-whisper / TTS 引擎）——
        m("Whisper Large v3 Turbo", 1.55, 1.6, .speech, nil, 0.0, "多语转写，标配"),
        m("Parakeet TDT 0.6B", 0.6, 0.7, .speech, nil, 0.0, "英文转写极快"),
        m("Kokoro 82M", 0.082, 0.3, .speech, nil, 0.0, "轻量 TTS，英文自然"),
        m("CosyVoice2 0.5B", 0.5, 0.5, .speech, nil, 0.0, "中文 TTS，可克隆音色"),
        // —— 重排（检索后二次排序）——
        m("bge-reranker-v2-m3", 0.568, 1.1, .rerank, nil, 0.0, "中英重排，配 bge-m3"),
        m("jina-reranker-v2", 0.278, 0.6, .rerank, nil, 0.0, "轻量重排"),
        // —— 向量/嵌入模型（不用于对话，供知识库检索）——
        m("bge-m3", 0.568, 1.2, .embed, "bge-m3", 0.02, "中英多语，MTEB 通用首选"),
        m("nomic-embed-text", 0.137, 0.27, .embed, "nomic-embed-text", 0.01, "轻量，长文检索"),
        m("mxbai-embed-large", 0.334, 0.65, .embed, "mxbai-embed-large", 0.02, "英文检索强"),
        m("snowflake-arctic-embed2", 0.568, 1.2, .embed, "snowflake-arctic-embed2", 0.02, "多语，企业检索"),
        m("bge-large-zh-v1.5", 0.326, 0.65, .embed, nil, 0.02, "中文小语料最稳"),
        m("Qwen3-Embedding 0.6B", 0.6, 0.64, .embed, nil, 0.02, "中文 + 多语，指令式"),
    ]

    private static func m(_ name: String, _ p: Double, _ q4: Double, _ c: ModelCategory,
                          _ tag: String?, _ kv: Double, _ note: String,
                          active: Double? = nil) -> LocalModel {
        LocalModel(name: name, paramsB: p, activeB: active ?? p, q4GB: q4,
                   cat: c, tag: tag, kv1k: kv, note: note)
    }
}


// MARK: - 能力画像

/// 七维能力分（1–5）。**这是按模型家族与规模推导的编辑先验，不是公开基准测试分数。**
/// 用途：在同一台机器"都跑得动"的候选之间做取舍；不用于跨硬件比较。
struct Capability {
    var zh: Double = 3.0        // 中文语感
    var writing: Double = 3.0   // 长文/学术写作
    var code: Double = 3.0      // 代码生成与理解
    var math: Double = 3.0      // 数理推理
    var tools: Double = 3.0     // 指令遵循与工具调用
    var vision: Double = 1.0    // 图像理解
    var follow: Double = 3.0    // 长上下文与格式约束

    var vector: [Double] { [zh, writing, code, math, tools, vision, follow] }
}

enum CapabilityModel {
    static func of(_ m: LocalModel) -> Capability {
        let n = m.name.lowercased()
        var c = Capability()

        // 家族先验：中文
        let zhStrong = ["qwen", "glm", "ernie", "deepseek", "hunyuan", "minicpm", "internlm", "yi 1.5"]
        c.zh = zhStrong.contains(where: { n.contains($0) }) ? 4.6 : 3.0
        if n.contains("gemma") { c.zh = 3.8 }
        if n.contains("llama") || n.contains("mistral") || n.contains("mixtral") { c.zh = 2.8 }

        // 规模带来的通用能力：0.3B → 2.2，120B → 4.4
        let tier = min(1.0, max(0.0, log10(max(0.3, m.paramsB)) / log10(120.0)))
        let general = 2.2 + 2.2 * tier

        let coderFamily = n.contains("coder") || n.contains("devstral")
        c.writing = general * (coderFamily ? 0.75 : 1.0)
        c.code = coderFamily ? 4.8 : general * 0.85
        c.math = m.cat == .reason ? 4.7 : general * 0.8
        c.tools = m.cat == .agent ? 4.7 : general * 0.75
        c.vision = m.cat == .vision ? 4.7 : 1.0
        c.follow = general * 0.95

        // 家族微调
        if n.contains("glm") { c.zh = 4.8; c.tools += 0.3 }
        if n.contains("deepseek") { c.math += 0.4 }
        if n.contains("gemma") { c.writing += 0.3 }
        if n.contains("granite") { c.follow += 0.3 }
        if n.contains("nemotron") { c.tools += 0.4 }
        if m.cat == .embed { c = Capability(zh: 1, writing: 1, code: 1, math: 1, tools: 1, vision: 1, follow: 1) }

        c.zh = clamp(c.zh); c.writing = clamp(c.writing); c.code = clamp(c.code)
        c.math = clamp(c.math); c.tools = clamp(c.tools); c.vision = clamp(c.vision)
        c.follow = clamp(c.follow)
        return c
    }

    private static func clamp(_ v: Double) -> Double { min(5.0, max(1.0, v)) }
}

// MARK: - 适配判定

enum FitLevel {
    case plenty      // 余量充足，可上更高精度
    case smooth      // 流畅
    case ok          // 可运行
    case tight       // 偏紧，需降上下文
    case tooHeavy    // 超出预算

    var label: String {
        switch self {
        case .plenty: return "余量充足"
        case .smooth: return "流畅"
        case .ok: return "可运行"
        case .tight: return "偏紧"
        case .tooHeavy: return "超出预算"
        }
    }
}

struct Advice: Identifiable {
    var id: String { model.name }
    let model: LocalModel
    let needGB: Double
    let ratio: Double
    let level: FitLevel
    let estTokS: Double
}

// MARK: - 引擎与已装模型

struct Engine: Identifiable {
    var id: String { name }
    let name: String
    let path: String
    let version: String
    var ready: Bool
    let installURL: String
    let role: String
}

struct InstalledModel: Identifiable {
    var id: String { "\(engine)/\(name)" }
    let name: String
    let sizeGB: Double
    let engine: String
    let quant: String
    var digest: String = ""
    var modified: String = "—"
    var path: String = ""
    /// 只有 Ollama 的模型能由本应用删除（走 ollama rm）；LM Studio 目录属外部管理，只提供定位
    var deletable: Bool { engine == "Ollama" }
}

/// 模型能力类型（用于「已装/对话/智能体」里给用户一个直观的类型标识）。
enum ModelKind {
    case vision      // 多模态：能看图
    case text        // 纯文本：只能对话
    case embed       // 嵌入：只出向量，不能对话
    case unknown     // 无法判断

    var label: String {
        switch self {
        case .vision: return "多模态"
        case .text: return "文本"
        case .embed: return "嵌入"
        case .unknown: return "—"
        }
    }
}

enum Runtime {
    static func detect() -> [Engine] {
        var list: [Engine] = []

        if let p = Sh.find("ollama") {
            let out = Sh.run(p, ["--version"])
            let v = out.replacingOccurrences(of: "ollama version is", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            list.append(Engine(name: "Ollama", path: p, version: v.isEmpty ? "已安装" : v,
                               ready: true, installURL: "https://ollama.com/download/mac",
                               role: "MLX/GGUF 双引擎，命令行 + API"))
        } else {
            list.append(Engine(name: "Ollama", path: "未找到", version: "未安装", ready: false,
                               installURL: "https://ollama.com/download/mac", role: "MLX/GGUF 双引擎"))
        }

        let lsPaths = ["/Applications/LM Studio.app", NSHomeDirectory() + "/Applications/LM Studio.app"]
        if let hit = lsPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            list.append(Engine(name: "LM Studio", path: hit, version: "已安装", ready: true,
                               installURL: "https://lmstudio.ai", role: "图形界面 + MLX，适合手动试模型"))
        } else {
            list.append(Engine(name: "LM Studio", path: "未找到", version: "未安装", ready: false,
                               installURL: "https://lmstudio.ai", role: "图形界面 + MLX"))
        }

        let omlx = "/Applications/oMLX.app"
        if FileManager.default.fileExists(atPath: omlx) {
            list.append(Engine(name: "oMLX", path: omlx, version: "已安装", ready: true,
                               installURL: "https://github.com/omlx", role: "MLX 原生推理"))
        }

        if let p = Sh.find("llama-server") ?? Sh.find("llama-cli") {
            list.append(Engine(name: "llama.cpp", path: p, version: "已安装", ready: true,
                               installURL: "https://github.com/ggml-org/llama.cpp",
                               role: "GGUF 原生，MindModel 调的就是它"))
        } else {
            list.append(Engine(name: "llama.cpp", path: "未找到", version: "未安装", ready: false,
                               installURL: "https://github.com/ggml-org/llama.cpp",
                               role: "GGUF 原生引擎（brew install llama.cpp）"))
        }

        list.append(Engine(name: "Apple MLX", path: "系统", version: "随 macOS", ready: true,
                           installURL: "https://github.com/ml-explore/mlx",
                           role: "Apple 官方张量框架，M 系列最快路径"))

        // —— 文生图后端（Ollama 不跑图，需 ComfyUI 或 stable-diffusion.cpp）——
        let comfyPaths = ["/Applications/ComfyUI.app", NSHomeDirectory() + "/ComfyUI",
                          NSHomeDirectory() + "/Applications/ComfyUI.app"]
        if let hit = comfyPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            list.append(Engine(name: "ComfyUI", path: hit, version: "已安装", ready: true,
                               installURL: "https://www.comfy.org", role: "文生图/视频节点工作流"))
        } else {
            list.append(Engine(name: "ComfyUI", path: "未找到", version: "未安装", ready: false,
                               installURL: "https://www.comfy.org", role: "文生图/视频节点工作流"))
        }

        let sdcppHome = NSHomeDirectory() + "/stable-diffusion.cpp"
        if let p = Sh.find("sd") ?? Sh.find("sd-server") {
            list.append(Engine(name: "stable-diffusion.cpp", path: p, version: "已安装", ready: true,
                               installURL: "https://github.com/leejet/stable-diffusion.cpp",
                               role: "GGUF 文生图，与 Ollama 同族"))
        } else if FileManager.default.fileExists(atPath: sdcppHome) {
            list.append(Engine(name: "stable-diffusion.cpp", path: sdcppHome, version: "已克隆", ready: false,
                               installURL: "https://github.com/leejet/stable-diffusion.cpp",
                               role: "GGUF 文生图（已克隆，未编出 sd 命令）"))
        } else {
            list.append(Engine(name: "stable-diffusion.cpp", path: "未找到", version: "未安装", ready: false,
                               installURL: "https://github.com/leejet/stable-diffusion.cpp",
                               role: "GGUF 文生图（brew install stable-diffusion-cpp）"))
        }
        return list
    }

    /// `ollama list` 的时间列是英文短语（"2 weeks ago"、"About an hour ago"），
    /// 直接显示会在中文界面里很跳。这里翻成"2 周前"，认不出的原样返回。
    static func zhAgo(_ raw: String) -> String {
        var t = raw.lowercased()
        guard !t.isEmpty, t != "—" else { return raw }
        t = t.replacingOccurrences(of: "less than a ", with: "1 ")
             .replacingOccurrences(of: "about ", with: "")
             .replacingOccurrences(of: " ago", with: "")
             .replacingOccurrences(of: "an ", with: "1 ")
        if t.hasPrefix("a ") { t = "1 " + t.dropFirst(2) }
        let parts = t.split(separator: " ").map(String.init)
        guard parts.count >= 2, let n = Int(parts[0]) else { return raw }
        let units: [String: String] = [
            "second": "秒", "seconds": "秒",
            "minute": "分钟", "minutes": "分钟",
            "hour": "小时", "hours": "小时",
            "day": "天", "days": "天",
            "week": "周", "weeks": "周",
            "month": "个月", "months": "个月",
            "year": "年", "years": "年",
        ]
        guard let u = units[parts[1]] else { return raw }
        return "\(n) \(u)前"
    }

    static func installed(ollamaPath: String?) -> [InstalledModel] {
        var out: [InstalledModel] = []
        if let p = ollamaPath {
            let txt = Sh.run(p, ["list"])
            for line in txt.split(separator: "\n").dropFirst() {
                let toks = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard let name = toks.first, !name.isEmpty, name != "NAME" else { continue }
                // ollama 输出形如 "qwen2.5:14b  id  9.0 GB  2 weeks ago"，数值与单位是两个词
                var size: Double = 0
                var unitIdx = -1
                if let i = toks.firstIndex(of: "GB"), i > 0, let v = Double(toks[i - 1]) {
                    size = v; unitIdx = i
                } else if let i = toks.firstIndex(of: "MB"), i > 0, let v = Double(toks[i - 1]) {
                    size = v / 1024; unitIdx = i
                } else {
                    for t in toks {
                        if t.hasSuffix("GB"), let v = Double(t.dropLast(2)) { size = v; break }
                        if t.hasSuffix("MB"), let v = Double(t.dropLast(2)) { size = v / 1024; break }
                    }
                }
                let digest = toks.count > 1 ? toks[1] : ""
                let modified = unitIdx > 0 && toks.count > unitIdx + 1
                    ? zhAgo(toks[(unitIdx + 1)...].joined(separator: " ")) : "—"
                out.append(InstalledModel(name: name, sizeGB: size, engine: "Ollama", quant: "—",
                                          digest: digest, modified: modified))
            }
        }
        // LM Studio 目录下的 gguf
        let root = NSHomeDirectory() + "/.lmstudio/models"
        let fm = FileManager.default
        if let en = fm.enumerator(atPath: root) {
            for case let rel as String in en where rel.lowercased().hasSuffix(".gguf") {
                let full = root + "/" + rel
                let sz = (try? fm.attributesOfItem(atPath: full))?[.size] as? NSNumber
                var q = "GGUF"
                let l = rel.lowercased()
                for cand in ["q4_k_m", "q4_k_s", "q5_k_m", "q6_k", "q8_0"] where l.contains(cand) {
                    q = cand.uppercased(); break
                }
                out.append(InstalledModel(name: (rel as NSString).lastPathComponent,
                                          sizeGB: (sz?.doubleValue ?? 0) / 1_073_741_824.0,
                                          engine: "LM Studio", quant: q, path: full))
            }
        }
        return out
    }
}

// MARK: - 模型仓库审计（只读扫描，不动文件）

/// Ollama 的模型由 manifest（JSON，声明用到哪些层）+ blobs（真正的数据块）组成。
/// 只看 `ollama list` 会漏掉两类真实问题：manifest 引用的层不存在（下载中断 / 手动删过 blob），
/// 以及没有任何 manifest 引用的孤儿块（白占磁盘、`ollama list` 里看不见）。
struct OllamaManifest: Identifiable {
    var id: String { name }
    let name: String            // qwen2.5:14b
    let path: String
    let sizeGB: Double          // 按 manifest 声明的各层大小求和
    let layerCount: Int
    let modified: Date?
    let missing: [String]       // 引用存在但 blob 缺失的层
    // 以下取自 config blob（几百字节的 JSON），不用读几十 GB 的权重
    var quant = "—"             // file_type，如 Q4_K_M
    var params = "—"            // model_type，如 14.8B
    var family = "—"            // model_family
    var capabilities: [String] = []
    var contextLen = 0
    var remote = false          // 有 remote_host 就是云端模型，权重不在本地
}

struct OrphanBlob: Identifiable {
    var id: String { digest }
    let digest: String
    let sizeGB: Double
    let path: String
}

struct DiskScan {
    var root = ""
    var rootExists = false
    var manifests: [OllamaManifest] = []
    var orphanBlobs: [OrphanBlob] = []
    var blobTotalGB: Double = 0
    var modelTotalGB: Double = 0
    var reclaimableGB: Double = 0
    var scannedAt: Date?

    var modelCount: Int { manifests.count }
}

enum ModelAudit {
    /// 允许用 OLLAMA_MODELS 覆盖，与 ollama 自己的规则一致
    static var root: String {
        if let e = ProcessInfo.processInfo.environment["OLLAMA_MODELS"], !e.isEmpty { return e }
        return NSHomeDirectory() + "/.ollama/models"
    }

    static func scan() -> DiskScan {
        var d = DiskScan()
        let fm = FileManager.default
        let root = Self.root
        d.root = root
        let mroot = root + "/manifests"
        let broot = root + "/blobs"
        guard fm.fileExists(atPath: mroot) else { return d }
        d.rootExists = true

        // 1) blobs：sha256-<hex> → digest
        var blobs: [String: (Int64, String)] = [:]
        if let en = fm.enumerator(atPath: broot) {
            for case let rel as String in en {
                let full = broot + "/" + rel
                guard let attr = try? fm.attributesOfItem(atPath: full),
                      let sz = attr[.size] as? NSNumber else { continue }
                let digest = rel.replacingOccurrences(of: "sha256-", with: "sha256:")
                blobs[digest] = (sz.int64Value, full)
                d.blobTotalGB += sz.doubleValue / 1_000_000_000.0
            }
        }

        // 2) manifests：registry.ollama.ai/library/<模型>/<标签>
        var referenced = Set<String>()
        if let en = fm.enumerator(atPath: mroot) {
            for case let rel as String in en {
                let full = mroot + "/" + rel
                guard let data = fm.contents(atPath: full),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let layers = obj["layers"] as? [[String: Any]] else { continue }
                let parts = rel.split(separator: "/").map(String.init)
                guard parts.count >= 2 else { continue }
                let tag = parts[parts.count - 1]
                let base = parts[parts.count - 2]
                var digests: [String] = []
                var bytes: Int64 = 0
                if let cfg = obj["config"] as? [String: Any], let dg = cfg["digest"] as? String {
                    digests.append(dg)
                    bytes += (cfg["size"] as? NSNumber)?.int64Value ?? 0
                }
                for l in layers {
                    guard let dg = l["digest"] as? String else { continue }
                    digests.append(dg)
                    bytes += (l["size"] as? NSNumber)?.int64Value ?? 0
                }
                let missing = digests.filter { blobs[$0] == nil }
                referenced.formUnion(digests)
                let mtime = (try? fm.attributesOfItem(atPath: full))?[.modificationDate] as? Date
                var man = OllamaManifest(
                    name: "\(base):\(tag)", path: full,
                    sizeGB: Double(bytes) / 1_000_000_000.0,
                    layerCount: layers.count, modified: mtime, missing: missing)
                if let cfg = obj["config"] as? [String: Any],
                   let cd = cfg["digest"] as? String,
                   let bp = blobs[cd]?.1,
                   let raw = fm.contents(atPath: bp),
                   let meta = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
                    if let v = meta["file_type"] as? String { man.quant = v }
                    if let v = meta["model_type"] as? String { man.params = v }
                    if let v = meta["model_family"] as? String { man.family = v }
                    if let v = meta["capabilities"] as? [String] { man.capabilities = v }
                    if let v = meta["context_length"] as? Int { man.contextLen = v }
                    man.remote = (meta["remote_host"] as? String) != nil
                }
                d.manifests.append(man)
            }
        }

        // 3) 孤儿：没有任何 manifest 引用的块
        for (dg, info) in blobs where !referenced.contains(dg) {
            d.orphanBlobs.append(OrphanBlob(digest: dg,
                                            sizeGB: Double(info.0) / 1_000_000_000.0,
                                            path: info.1))
        }
        d.orphanBlobs.sort { $0.sizeGB > $1.sizeGB }
        d.reclaimableGB = d.orphanBlobs.reduce(0) { $0 + $1.sizeGB }
        d.modelTotalGB = d.manifests.reduce(0) { $0 + $1.sizeGB }
        d.manifests.sort { $0.sizeGB > $1.sizeGB }
        d.scannedAt = Date()
        return d
    }
}

// MARK: - 体检结论

struct HealthIssue: Identifiable {
    enum Severity: String {
        case critical = "严重"
        case warning = "注意"
        case info = "提示"
    }
    var id: String
    let severity: Severity
    let title: String
    let detail: String
    /// 相关模型名；有值时界面提供"删除"入口
    var model: String?
}

extension DiskScan {
    /// budgetGB：本机可承载预算，用来判断"装得下但跑不动"
    func issues(budgetGB: Double) -> [HealthIssue] {
        var out: [HealthIssue] = []

        if !rootExists {
            out.append(HealthIssue(id: "noroot", severity: .info,
                                   title: "没找到 Ollama 模型目录",
                                   detail: "\(root) 不存在。可能是没装 Ollama，或用 OLLAMA_MODELS 指到了别处。"))
            return out
        }

        // 缺层：这是真正会让 ollama run 直接失败的问题
        for m in manifests where !m.missing.isEmpty {
            out.append(HealthIssue(
                id: "missing-\(m.name)", severity: .critical,
                title: "\(m.name) 缺 \(m.missing.count) 个数据层，加载会失败",
                detail: "manifest 里声明了这些层，但 blobs 目录里找不到。常见于下载中断或手动清理过 blob。删除后重新拉取即可修复。",
                model: m.name))
        }

        // 孤儿块：白占空间
        if reclaimableGB >= 0.05 {
            out.append(HealthIssue(
                id: "orphan", severity: .warning,
                title: String(format: "有 %.1f GB 无主数据块可回收", reclaimableGB),
                detail: "\(orphanBlobs.count) 个 blob 没有被任何模型引用。`ollama list` 看不到它们，但确实占着磁盘。本应用不会自动删——确认后可用下方按钮清理。"))
        }

        // 装得下 ≠ 跑得动
        if budgetGB > 1 {
            for m in manifests where m.sizeGB / budgetGB > 0.92 {
                let ratio = m.sizeGB / budgetGB * 100
                out.append(HealthIssue(
                    id: "heavy-\(m.name)", severity: .warning,
                    title: String(format: "%@ 占预算 %.0f%%，留不下上下文空间", m.name, ratio),
                    detail: String(format: "光权重就 %.1f GB，本机预算 %.1f GB。能加载，但开不了长上下文，也容易被系统换出。换 Q4 或更小档位更实用。", m.sizeGB, budgetGB),
                    model: m.name))
            }
        }

        // 同族多版本
        var byBase: [String: [OllamaManifest]] = [:]
        for m in manifests {
            let base = m.name.split(separator: ":").first.map(String.init) ?? m.name
            byBase[base, default: []].append(m)
        }
        for (base, list) in byBase where list.count > 1 {
            let total = list.reduce(0.0) { $0 + $1.sizeGB }
            out.append(HealthIssue(
                id: "dup-\(base)", severity: .info,
                title: String(format: "%@ 存了 %d 个版本，合计 %.1f GB", base, list.count, total),
                detail: "同一模型的多个标签：\(list.map { $0.name }.sorted().joined(separator: "、"))。只留常用的那个能立刻释放空间。"))
        }

        if manifests.isEmpty && orphanBlobs.isEmpty {
            out.append(HealthIssue(id: "empty", severity: .info,
                                   title: "还没有下载任何模型",
                                   detail: "到「模型推荐」里挑一个拉取，或到「导入 GGUF」加载本地文件。"))
        }
        return out
    }

    var criticalCount: Int {
        // 只统计严重级别，用于概览页的红点
        manifests.filter { !$0.missing.isEmpty }.count
    }
}

// MARK: - Ollama 模型命名

enum OllamaName {
    /// 把任意文件名/用户输入规范成合法模型名
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasSuffix(".gguf") { s = String(s.dropLast(5)) }
        s = String(s.map { ch -> Character in
            if ch.isASCII && (ch.isLetter || ch.isNumber) { return ch }
            if ch == "-" || ch == "_" || ch == "." || ch == ":" { return ch }
            return "-"
        })
        while s.contains("--") { s = s.replacingOccurrences(of: "--", with: "-") }
        while let f = s.first, f == "-" || f == "_" || f == "." { s.removeFirst() }
        while let l = s.last, l == "-" || l == "_" || l == "." { s.removeLast() }
        if s.isEmpty { s = "model" }
        if s.count > 64 { s = String(s.prefix(64)) }
        return s
    }

    /// 返回 nil 表示合法；否则是给人看的错误原因
    static func problem(_ name: String) -> String? {
        if name.isEmpty { return "名称不能为空" }
        if name.count > 64 { return "名称最长 64 个字符" }
        let ok = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-.:")
        if name.unicodeScalars.contains(where: { !ok.contains($0) }) {
            return "只允许小写字母、数字与 - _ . :"
        }
        if let f = name.first, "-_.".contains(f) { return "不能以 \(f) 开头" }
        if name.filter({ $0 == ":" }).count > 1 { return "只能有一个 : 用来分隔标签" }
        return nil
    }
}
