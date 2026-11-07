import Foundation

// MARK: - HuggingFace 在线模型搜索

/// 模型格式过滤（可设置）。GGUF 是本应用能直接导入 Ollama 用的格式；
/// 「全部格式」会把 safetensors 等原始权重也列出来（供了解/转换，不能直接导入）。
enum ModelFormat: String, CaseIterable, Identifiable {
    case ggufOnly = "gguf"
    case all = "all"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ggufOnly: return "仅 GGUF"
        case .all: return "全部格式"
        }
    }

    /// 该格式下是否应包含某个文件（按扩展名粗判）
    func accepts(fileName: String) -> Bool {
        if self == .all { return true }
        let p = fileName.lowercased()
        return p.hasSuffix(".gguf") || p.hasSuffix(".mmproj")
    }
}

/// 参数量筛选（十亿参数为界），用于快速缩小选型范围。
enum ParamFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case upTo8B = "≤8B"
    case upTo14B = "≤14B"
    case upTo32B = "≤32B"
    case upTo70B = "≤70B"

    var id: String { rawValue }
    var label: String { rawValue }

    /// 该筛选是否接受某个参数量（nil = 无法识别，按「接受」处理，交给用户自己判断）
    func accepts(_ b: Double?) -> Bool {
        guard let b else { return true }
        switch self {
        case .all: return true
        case .upTo8B: return b <= 8
        case .upTo14B: return b <= 14
        case .upTo32B: return b <= 32
        case .upTo70B: return b <= 70
        }
    }
}

/// 结果排序方式。
enum SortOrder: String, CaseIterable, Identifiable {
    case downloads = "下载量"
    case params = "参数量"

    var id: String { rawValue }
    var label: String { rawValue }
}


/// HuggingFace 上的一条 GGUF 模型搜索结果。
/// 只用于「在线找模型」——内置目录仍以 data/models.toml 为权威，这里提供的是
/// 清单之外、社区持续更新的 GGUF 模型入口。
struct HFModel: Identifiable, Codable {
    var id: String { modelId }
    let modelId: String          // 形如 "Qwen/Qwen2.5-7B-Instruct-GGUF"
    let downloads: Int           // 全库下载量
    let likes: Int
    let tags: [String]
    let createdAt: String
    let gated: Bool              // 是否需登录授权才能下载（来自 HF 的 private 字段）

    var license: String {
        tags.first { $0.hasPrefix("license:") }
            .map { String($0.dropFirst("license:".count)) } ?? "未知"
    }

    /// 是否明确标注了 GGUF（有些仓库是 safetensors + gguf 混合）
    var isGGUF: Bool { tags.contains("gguf") }

    /// 详情页 URL（走镜像可达的网页端）
    var pageURL: URL? { URL(string: "https://hf-mirror.com/\(modelId)") }

    /// 仓库树 API（列出文件，找 .gguf 下载链接）
    var treeURL: URL? { URL(string: "https://hf-mirror.com/api/models/\(modelId)/tree/main") }

    enum CodingKeys: String, CodingKey {
        case modelId, downloads, likes, tags, createdAt
        case gated = "private"   // HF API 里"是否需授权"字段叫 private，不是 gated
    }

    /// gated 字段可能缺失（HF 对公开仓库常不返回 private 字段），默认 false。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelId = try c.decode(String.self, forKey: .modelId)
        downloads = try c.decodeIfPresent(Int.self, forKey: .downloads) ?? 0
        likes = try c.decodeIfPresent(Int.self, forKey: .likes) ?? 0
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        gated = try c.decodeIfPresent(Bool.self, forKey: .gated) ?? false
    }
}

/// HuggingFace 搜索 API 客户端。零依赖，用 URLSession。
/// 域名默认走 hf-mirror.com（国内可达），原始 huggingface.co 在本机被墙。
/// 用环境变量 HF_ENDPOINT 可覆盖（例如设回 https://huggingface.co）。
enum HFSearch {
    static let base: String = {
        if let ep = ProcessInfo.processInfo.environment["HF_ENDPOINT"], !ep.isEmpty {
            return ep.hasSuffix("/") ? ep + "api/models" : ep + "/api/models"
        }
        return "https://hf-mirror.com/api/models"
    }()

    /// 搜索模型。q 为空时返回热门模型。format 为 .ggufOnly 时只搜 GGUF，.all 时搜全部格式。
    static func search(_ q: String, format: ModelFormat = .ggufOnly, limit: Int = 50) async throws -> [HFModel] {
        var comps = URLComponents(string: base)!
        var items = [URLQueryItem(name: "limit", value: String(limit)),
                     URLQueryItem(name: "sort", value: "downloads"),
                     URLQueryItem(name: "direction", value: "-1")]
        if format == .ggufOnly {
            items.append(URLQueryItem(name: "filter", value: "gguf"))
        }
        let t = q.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty {
            items.append(URLQueryItem(name: "search", value: t))
        }
        comps.queryItems = items

        let (data, resp) = try await URLSession.shared.data(from: comps.url!)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "HF", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HuggingFace 返回 \(http.statusCode)"])
        }
        return try JSONDecoder().decode([HFModel].self, from: data)
    }

    /// 列出某个仓库里的文件（含大小）。format 为 .ggufOnly 时只列 .gguf/.mmproj，
    /// .all 时列出全部文件（如 safetensors 原始权重）。
    static func files(_ modelId: String, format: ModelFormat = .ggufOnly) async throws -> [HFFile] {
        let url = URL(string: "https://hf-mirror.com/api/models/\(modelId)/tree/main")!
        let (data, resp) = try await URLSession.shared.data(from: url)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "HF", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "无法读取仓库文件列表"])
        }
        let files = try JSONDecoder().decode([HFFile].self, from: data)
        return files
            .filter { $0.type == "file" }
            .filter { format.accepts(fileName: $0.path) }
            .sorted { $0.size > $1.size }
    }

    /// 兼容旧调用：列出 .gguf/.mmproj 文件。
    static func ggufFiles(_ modelId: String) async throws -> [HFFile] {
        try await files(modelId, format: .ggufOnly)
    }
}

/// 仓库树里的一个文件
struct HFFile: Codable, Identifiable {
    let path: String
    let size: Int
    let type: String
    var id: String { path }

    /// LFS 的 sha256（HF 上 GGUF 通常走 LFS，oid 即文件内容的 sha256）
    var sha256: String? {
        lfs?.oid
    }
    private let lfs: LFS?

    struct LFS: Codable {
        let oid: String
        let size: Int
    }

    enum CodingKeys: String, CodingKey {
        case path, size, type, lfs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "file"
        lfs = try c.decodeIfPresent(LFS.self, forKey: .lfs)
    }

    var sizeGB: String {
        let gb = Double(size) / 1_073_741_824.0
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(size) / 1_048_576.0)
    }

    /// 直链（走 hf-mirror resolve，国内可达）：
    /// https://hf-mirror.com/{modelId}/resolve/main/{path}
    func downloadURL(modelId: String) -> URL? {
        let p = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "https://hf-mirror.com/\(modelId)/resolve/main/\(p)")
    }

    /// 是否 gguf 文件（含 mmproj 投影器）
    var isGGUF: Bool {
        let p = path.lowercased()
        return p.hasSuffix(".gguf") || p.hasSuffix(".mmproj")
    }

    /// 是否投影器（mmproj / clip 视觉编码器），不是主模型
    var isProjector: Bool {
        let p = path.lowercased()
        return p.contains("mmproj") || p.contains("clip")
    }

    /// 是否辅助文件（imatrix 校准矩阵、tokenizer 等），既不是主模型也不是投影器，不该被当作模型下载
    var isAux: Bool {
        let p = path.lowercased()
        return p.contains("imatrix") || p.contains("tokenizer") || p.contains("chat.template")
    }
}

/// 一个正在浏览文件列表的 HF 仓库（用于 sheet(item:) 弹层）。
struct HFListing: Identifiable {
    let modelId: String
    var id: String { modelId }
}

// MARK: - ModelScope（魔搭）在线搜索

/// 魔搭社区的一条模型。字段比 HF 精简：Path+Name 拼成 model id，
/// 下载量与 license 直接可用。
struct MSModel: Identifiable, Codable {
    var id: String { path + "/" + name }
    let path: String          // 组织名，如 "Qwen"
    let name: String          // 模型名，如 "Qwen2.5-7B-Instruct-GGUF"
    let downloads: Int
    let license: String
    let createdTime: Int      // Unix 秒
    let stars: Int            // 社区星标数（评价）
    let chineseName: String   // 中文名，如「千问3-VL-8B-Instruct」
    let storageSize: Int64    // 仓库体积（字节）
    let tasks: [String]       // 任务名，如 "image-text-to-text"（视觉多模态）
    let modelType: [String]   // 模型类型，如 "qwen3_vl"

    var pageURL: URL? { URL(string: "https://modelscope.cn/models/\(path)/\(name)") }
    var isGGUF: Bool { name.lowercased().contains("gguf") }

    /// 是否视觉多模态模型（从 Tasks 的 image-text-to-text / domain 判断）
    var isVision: Bool {
        tasks.contains { $0.lowercased().contains("image-text-to-text")
                         || $0.lowercased().contains("multi-modal") }
        || modelType.contains { $0.lowercased().contains("vl") }
        || name.lowercased().contains("-vl") || name.lowercased().contains("vl-")
    }

    /// 体积的可读显示
    var sizeText: String {
        guard storageSize > 0 else { return "" }
        let gb = Double(storageSize) / 1_073_741_824.0
        if gb >= 100 { return String(format: "%.0f GB", gb) }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(storageSize) / 1_048_576.0)
    }

    /// 本地推断的一句话简介：从 tasks 中文名 + 模型类型拼出「这是什么模型」。
    /// 详情页还有更全的 README 摘要。
    var oneLineIntro: String {
        var parts: [String] = []
        // tasks 里带中文名（"image-text-to-text" 之类英文名不用，只取有意义的中文）
        for t in tasks {
            let low = t.lowercased()
            if low.contains("image-text-to-text") || low.contains("multi-modal") || low.contains("vision") {
                parts.append("视觉多模态理解")
            } else if low.contains("text-generation") || low.contains("chat") || low.contains("conversational") {
                parts.append("对话文本生成")
            } else if low.contains("embedding") {
                parts.append("文本嵌入")
            }
        }
        if modelType.contains(where: { $0.lowercased().contains("vl") }) && !parts.contains("视觉多模态理解") {
            parts.append("视觉多模态理解")
        }
        // 去重保序
        var seen = Set<String>()
        let uniq = parts.filter { seen.insert($0).inserted }
        if uniq.isEmpty {
            return isGGUF ? "GGUF 量化模型，点「详情」查看完整介绍" : "点「详情」查看完整介绍"
        }
        return uniq.joined(separator: " · ")
    }

    enum CodingKeys: String, CodingKey {
        case path = "Path", name = "Name", downloads = "Downloads",
             license = "License", createdTime = "CreatedTime",
             stars = "Stars", chineseName = "ChineseName",
             storageSize = "StorageSize", tasks = "Tasks", modelType = "ModelType"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        name = try c.decode(String.self, forKey: .name)
        downloads = try c.decodeIfPresent(Int.self, forKey: .downloads) ?? 0
        license = try c.decodeIfPresent(String.self, forKey: .license) ?? "未知"
        createdTime = try c.decodeIfPresent(Int.self, forKey: .createdTime) ?? 0
        stars = try c.decodeIfPresent(Int.self, forKey: .stars) ?? 0
        chineseName = try c.decodeIfPresent(String.self, forKey: .chineseName) ?? ""
        storageSize = try c.decodeIfPresent(Int64.self, forKey: .storageSize) ?? 0
        modelType = try c.decodeIfPresent([String].self, forKey: .modelType) ?? []
        // Tasks 是嵌套数组 [{"Name":"image-text-to-text", "ChineseName":"视觉多模态理解", ...}]
        if let arr = try c.decodeIfPresent([MSTask].self, forKey: .tasks) {
            tasks = arr.map { $0.name }
        } else {
            tasks = []
        }
    }
}

/// 魔搭 Tasks 数组里的一项（只需 Name 字段用于判断类型）。
struct MSTask: Codable {
    let name: String
    let chineseName: String
    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case chineseName = "ChineseName"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        chineseName = try c.decodeIfPresent(String.self, forKey: .chineseName) ?? ""
    }
}

// MARK: - 模型详情（点「详情」时抓取，用于展示「这模型是什么/怎么来的」）

/// 一个模型的详情信息。从魔搭详情 API 提取，供下载前了解模型特点。
struct ModelDetail {
    let chineseName: String
    let organization: String    // 组织名（如「千问」）
    let architectures: [String] // 架构
    let tasks: [String]         // 任务中文名
    let arxivIds: [String]      // 相关论文 arxiv ID
    let readmeSummary: String   // README 摘要（去 HTML 的前若干段）
    let license: String
    let downloads: Int
    let stars: Int
    let pageURL: URL?

    /// 一句话简介：本地从任务/架构推断的「这是什么模型」。优先中文任务名，架构英文名作兜底。
    var oneLineSummary: String {
        var parts: [String] = []
        if !tasks.isEmpty {
            parts.append(contentsOf: tasks)
        }
        if parts.isEmpty, let arch = architectures.first, !arch.isEmpty {
            parts.append(arch)
        }
        if parts.isEmpty {
            return "暂无简介，点「在网页查看」了解详情"
        }
        return parts.joined(separator: " · ")
    }
}

/// 魔搭详情 API 客户端。点「详情」时按需抓取，不阻塞搜索列表。
enum MSDetail {
    static func fetch(path: String, name: String) async -> ModelDetail? {
        let p = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let n = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        guard let url = URL(string: "https://modelscope.cn/api/v1/models/\(p)/\(n)") else { return nil }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let d = try JSONDecoder().decode(DetailResponse.self, from: data)
            return d.model.toModelDetail(path: path, name: name)
        } catch {
            return nil
        }
    }
}

/// 详情 API 返回的原始结构（只解码需要的字段，其余忽略）。
struct DetailResponse: Codable {
    struct DetailData: Codable {
        let ChineseName: String?
        let ReadMeContent: String?
        let Architectures: [String]?
        let Tasks: [MSTask]?
        let RelatedArxivId: [String]?
        let Organization: Org?
        let License: String?
        let Downloads: Int?
        let Stars: Int?
        struct Org: Codable {
            let FullName: String?
        }
    }
    let Data: DetailData

    var model: DetailData { Data }
}

extension DetailResponse.DetailData {
    func toModelDetail(path: String, name: String) -> ModelDetail {
        let readme = ReadMeContent ?? ""
        let summary = Self.summarize(readme)
        let taskNames = (Tasks ?? []).map { $0.chineseName.isEmpty ? $0.name : $0.chineseName }
        return ModelDetail(
            chineseName: ChineseName ?? "",
            organization: Organization?.FullName ?? "",
            architectures: Architectures ?? [],
            tasks: taskNames,
            arxivIds: RelatedArxivId ?? [],
            readmeSummary: summary,
            license: License ?? "未知",
            downloads: Downloads ?? 0,
            stars: Stars ?? 0,
            pageURL: URL(string: "https://modelscope.cn/models/\(path)/\(name)"))
    }

    /// 把 README（HTML/Markdown 混杂）剥离标签，截取前若干字作为摘要。
    static func summarize(_ html: String) -> String {
        // 去 HTML 标签
        var t = html
        t = t.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // 去 Markdown 符号与多余空白
        t = t.replacingOccurrences(of: "```", with: " ")
        t = t.replacingOccurrences(of: "\\n", with: " ")
        t = t.replacingOccurrences(of: "\n", with: " ")
        t = t.replacingOccurrences(of: "#", with: " ")
        t = t.replacingOccurrences(of: "*", with: " ")
        t = t.replacingOccurrences(of: "|", with: " ")
        // 折叠连续空白
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = 600
        if trimmed.count <= limit { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }
}

/// ModelScope 搜索。用 PUT 方法（官方前端即如此），零依赖。
enum MSSearch {
    static let url = "https://modelscope.cn/api/v1/dolphin/models"

    struct Response: Codable {
        struct Data: Codable {
            struct Model: Codable {
                let Models: [MSModel]
                let TotalCount: Int
            }
            let Model: Model
        }
        let Data: Data
        let Code: Int
    }

    static func search(_ q: String, format: ModelFormat = .ggufOnly, limit: Int = 50) async throws -> [MSModel] {
        let t = q.trimmingCharacters(in: .whitespaces)
        // 空查询：ggufOnly 时搜 "GGUF" 拿热门 GGUF；all 时用通用热门词。
        // 有查询时直接用它，让魔搭返回尽可能多的候选，再由 format 在客户端过滤。
        let name: String
        if !t.isEmpty {
            name = t
        } else {
            name = format == .ggufOnly ? "GGUF" : "大模型"
        }
        let body: [String: Any] = [
            "Name": name, "PageSize": limit, "PageNumber": 1, "SortBy": "Default"
        ]
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "MS", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "魔搭返回 \(http.statusCode)"])
        }
        let r = try JSONDecoder().decode(Response.self, from: data)
        guard r.Code == 200 else {
            throw NSError(domain: "MS", code: r.Code,
                          userInfo: [NSLocalizedDescriptionKey: "魔搭搜索失败"])
        }
        let all = r.Data.Model.Models.filter { !$0.path.isEmpty && !$0.name.isEmpty }
        // 按格式过滤：ggufOnly 优先保留 GGUF；all 返回全部
        if format == .ggufOnly {
            let gguf = all.filter { $0.isGGUF }
            let picked = gguf.isEmpty ? all : gguf
            return picked.sorted { $0.downloads > $1.downloads }
        }
        return all.sorted { $0.downloads > $1.downloads }
    }
}
