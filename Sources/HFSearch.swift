import Foundation

// MARK: - HuggingFace 在线模型搜索

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

    /// 搜索 GGUF 模型。q 为空时返回热门 GGUF 模型。
    static func search(_ q: String, limit: Int = 50) async throws -> [HFModel] {
        var comps = URLComponents(string: base)!
        var items = [URLQueryItem(name: "filter", value: "gguf"),
                     URLQueryItem(name: "limit", value: String(limit)),
                     URLQueryItem(name: "sort", value: "downloads"),
                     URLQueryItem(name: "direction", value: "-1")]
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

    /// 列出某个仓库里的所有 .gguf 文件（含大小），用于给用户看"这个仓库有哪些量化可选"。
    static func ggufFiles(_ modelId: String) async throws -> [HFFile] {
        let url = URL(string: "https://hf-mirror.com/api/models/\(modelId)/tree/main")!
        let (data, resp) = try await URLSession.shared.data(from: url)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "HF", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "无法读取仓库文件列表"])
        }
        let files = try JSONDecoder().decode([HFFile].self, from: data)
        return files.filter { $0.path.lowercased().hasSuffix(".gguf") }
    }
}

/// 仓库树里的一个文件
struct HFFile: Codable {
    let path: String
    let size: Int
    let type: String

    var sizeGB: Double { Double(size) / 1_073_741_824.0 }
    var downloadURL: URL? {
        // 直链格式：https://hf-mirror.com/{model}/resolve/main/{path}
        let p = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "https://hf-mirror.com/\(p)") // 占位，实际拼在调用处
    }
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

    var pageURL: URL? { URL(string: "https://modelscope.cn/models/\(path)/\(name)") }
    var isGGUF: Bool { name.lowercased().contains("gguf") }

    enum CodingKeys: String, CodingKey {
        case path = "Path", name = "Name", downloads = "Downloads",
             license = "License", createdTime = "CreatedTime"
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

    static func search(_ q: String, limit: Int = 50) async throws -> [MSModel] {
        let t = q.trimmingCharacters(in: .whitespaces)
        // 空查询时搜 "GGUF"；有查询时直接用它，让魔搭返回尽可能多的候选，
        // 再由 isGGUF / 名称匹配在客户端过滤（避免服务端关键词太窄导致全空）。
        let name = t.isEmpty ? "GGUF" : t
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
        // 优先保留明确是 GGUF 的；若没有，退回按名称包含关键词的全部结果（不硬过滤）
        let gguf = all.filter { $0.isGGUF }
        let picked = gguf.isEmpty ? all : gguf
        return picked.sorted { $0.downloads > $1.downloads }
    }
}
