import Foundation

// MARK: - 魔搭（ModelScope）模型文件列表与直链下载
//
// 端点（均已实测通过）：
//   文件列表  GET  https://modelscope.cn/api/v1/models/{org}/{name}/repo/files?Revision=master&Recursive=true
//   直链下载  GET  https://modelscope.cn/api/v1/models/{org}/{name}/repo?Revision=master&FilePath={path}
//             支持 Range（断点续传），返回 206。
//
// 零依赖，纯 URLSession。下载走流式，逐块落盘并回报进度，避免大文件吃内存。

/// 魔搭仓库里的一个文件。
struct MSFile: Identifiable {
    let path: String
    let size: Int64
    let sha256: String?
    let isLFS: Bool
    var id: String { path }

    var sizeGB: String {
        let gb = Double(size) / 1_073_741_824.0
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(size) / 1_048_576.0)
    }

    /// 是否 gguf 文件（含投影器 mmproj）
    var isGGUF: Bool {
        let p = path.lowercased()
        return p.hasSuffix(".gguf") || p.hasSuffix(".mmproj")
    }
}

/// 一个正在浏览文件列表的魔搭仓库（用于 sheet(item:) 弹层）。
struct MSListing: Identifiable {
    let org: String
    let name: String
    let model: MSModel
    var id: String { org + "/" + name }
}

/// 魔搭下载客户端。
enum MSDownload {
    static let host = "https://modelscope.cn/api/v1/models"

    /// 列出仓库文件（过滤出 .gguf / .mmproj，按大小降序）。
    static func listFiles(org: String, name: String) async throws -> [MSFile] {
        let orgEnc = org.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? org
        let nameEnc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let urlStr = "\(host)/\(orgEnc)/\(nameEnc)/repo/files?Revision=master&Recursive=true"
        guard let url = URL(string: urlStr) else {
            throw NSError(domain: "MS", code: -1, userInfo: [NSLocalizedDescriptionKey: "仓库地址无效"])
        }
        let (data, resp) = try await URLSession.shared.data(from: url)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "MS", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "文件列表返回 \(http.statusCode)"])
        }
        struct Wrap: Codable {
            struct D: Codable { struct F: Codable {
                let Path: String; let Size: Int64; let Sha256: String?; let IsLFS: Bool?; let `Type`: String
            }; let Files: [F] }
            let Data: D
        }
        let w = try JSONDecoder().decode(Wrap.self, from: data)
        return w.Data.Files
            .filter { $0.Type == "blob" }
            .map { MSFile(path: $0.Path, size: $0.Size, sha256: $0.Sha256, isLFS: $0.IsLFS ?? false) }
            .filter { $0.isGGUF }
            .sorted { $0.size > $1.size }
    }

    /// 直链下载某个文件到本地目录。返回保存路径。
    /// onProgress: (已下载字节, 总字节) 在后台线程回调。
    /// 用 DataDelegate 流式接收，逐块落盘，避免大文件吃内存；支持 Range 断点续传。
    static func download(org: String, name: String, filePath: String,
                         to dir: URL,
                         onProgress: @escaping (Int64, Int64) -> Void) async throws -> URL {
        // FilePath 是 query 参数，用 urlQueryAllowed 转义（含 / 等字符），避免路径被截断
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "/+&=")
        let enc = filePath.addingPercentEncoding(withAllowedCharacters: allowed) ?? filePath
        let orgEnc = org.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? org
        let nameEnc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let urlStr = "\(host)/\(orgEnc)/\(nameEnc)/repo?Revision=master&FilePath=\(enc)"
        guard let url = URL(string: urlStr) else {
            throw NSError(domain: "MS", code: -1, userInfo: [NSLocalizedDescriptionKey: "下载地址无效"])
        }
        let saveName = (filePath as NSString).lastPathComponent
        return try await download(url: url, saveName: saveName, to: dir, onProgress: onProgress)
    }

    /// 通用直链流式下载（魔搭与 HuggingFace 直链共用）。
    static func download(url: URL, saveName: String, to dir: URL,
                         onProgress: @escaping (Int64, Int64) -> Void) async throws -> URL {
        let dest = dir.appendingPathComponent(saveName)

        // 已存在部分文件则断点续传
        var existingBytes: Int64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
           let existing = attrs[.size] as? Int64, existing > 0 {
            existingBytes = existing
        }

        var req = URLRequest(url: url)
        if existingBytes > 0 {
            req.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
        }

        let streamer = StreamDownloader(dest: dest, resumeAt: existingBytes, onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: streamer, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        // 用 dataTask（delegate 流式写盘），而非 data(for:)（会把整个响应累积进内存导致大文件 OOM）
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            streamer.onComplete = {
                cont.resume()
            }
            session.dataTask(with: req).resume()
        }

        if let e = streamer.error { throw e }
        return dest
    }
}

/// 流式下载：DataDelegate 逐块写盘，回报进度。不把整个文件留在内存。
final class StreamDownloader: NSObject, URLSessionDataDelegate {
    let dest: URL
    var resumeAt: Int64
    let onProgress: (Int64, Int64) -> Void
    var received: Int64 = 0
    var total: Int64 = 0
    var error: Error?
    var onComplete: (() -> Void)?
    private var fh: FileHandle?

    init(dest: URL, resumeAt: Int64, onProgress: @escaping (Int64, Int64) -> Void) {
        self.dest = dest
        self.resumeAt = resumeAt
        self.received = resumeAt   // 断点续传时进度从已有字节起算
        self.onProgress = onProgress
        super.init()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            if let r = http.value(forHTTPHeaderField: "Content-Range"),
               let last = r.split(separator: "/").last, let t = Int64(last) {
                total = t
            } else if let l = http.value(forHTTPHeaderField: "Content-Length"), let t = Int64(l) {
                total = t
            }
            // 服务器忽略 Range 返回 200（完整文件）时，从头写，不回退到 resumeAt
            if http.statusCode == 200 {
                resumeAt = 0
                received = 0
            }
        }
        do {
            if !FileManager.default.fileExists(atPath: dest.path) {
                FileManager.default.createFile(atPath: dest.path, contents: nil)
            }
            fh = try FileHandle(forWritingTo: dest)
            if resumeAt == 0 {
                try fh?.truncate(atOffset: 0)
            } else {
                try fh?.seek(toOffset: UInt64(resumeAt))
            }
        } catch {
            self.error = error
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do { try fh?.write(contentsOf: data) } catch { self.error = error }
        received += Int64(data.count)
        onProgress(received, total)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError err: Error?) {
        try? fh?.close()
        fh = nil
        if let err { self.error = err }
        onComplete?()
    }
}
