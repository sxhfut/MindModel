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

    /// 是否投影器（mmproj / clip 视觉编码器），不是主模型
    var isProjector: Bool {
        let p = path.lowercased()
        return p.contains("mmproj") || p.contains("clip")
    }

    /// 是否辅助文件（imatrix 校准矩阵、tokenizer 等），不该被当作模型下载
    var isAux: Bool {
        let p = path.lowercased()
        return p.contains("imatrix") || p.contains("tokenizer") || p.contains("chat.template")
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
    /// 内置断点续传 + 自动重试：直链（尤其魔搭）常中途断流，这里会把「没下满」的
    /// 情况自动重连续传，最多 maxRetries 轮，而不是让调用方拿到半个文件。
    static func download(url: URL, saveName: String, to dir: URL,
                         onProgress: @escaping (Int64, Int64) -> Void,
                         maxRetries: Int = 8) async throws -> URL {
        let dest = dir.appendingPathComponent(saveName)

        for _ in 0...maxRetries {
            if Task.isCancelled { throw CancellationError() }

            // 已存在部分文件则断点续传
            var existingBytes: Int64 = 0
            if let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
               let existing = attrs[.size] as? Int64, existing > 0 {
                existingBytes = existing
            }

            var req = URLRequest(url: url)
            // 连接/请求超时：默认 URLSession 无超时，服务器挂起时会永久卡住（「点了没反应」的根因）。
            // 大文件下载数据本身可能很慢，所以只给「建立连接」和「响应头」设短超时，
            // 数据体不设超时（由下面的「停滞看门狗」负责）。
            req.timeoutInterval = 60
            if existingBytes > 0 {
                req.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
            }

            let streamer = StreamDownloader(dest: dest, resumeAt: existingBytes, onProgress: onProgress)
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60        // 请求（含响应头）超时
            config.timeoutIntervalForResource = 0        // 资源总时长不设上限，交给看门狗
            let session = URLSession(configuration: config, delegate: streamer, delegateQueue: nil)

            await withTaskCancellationHandler {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    streamer.onComplete = {
                        cont.resume()
                    }
                    session.dataTask(with: req).resume()
                }
            } onCancel: {
                session.invalidateAndCancel()
            }
            session.invalidateAndCancel()

            if let e = streamer.error { throw e }
            if Task.isCancelled { throw CancellationError() }

            // 判定是否下满：total 未知（服务器没给长度）时，只要没报错就认为完成；
            // total 已知时，已下字节必须达到 total 才算完整，否则续传重试。
            let received = streamer.received
            let total = streamer.total
            if total <= 0 || received >= total {
                return dest
            }
            // 没下满 → 短暂等待后自动续传（保留已下部分，靠 Range 续传）
            try await Task.sleep(nanoseconds: 1_500_000_000)
        }

        throw NSError(domain: "MS", code: -2,
                      userInfo: [NSLocalizedDescriptionKey: "下载多次中断，仍未完成（已保留部分，可重试）"])
    }
}

/// 流式下载：DataDelegate 逐块写盘，回报进度。不把整个文件留在内存。
/// 内置「停滞看门狗」：若连续 `stallTimeout` 秒没有任何数据到达（服务器保持连接但已停止
/// 发送，或网络半开），主动取消任务并报错，避免 `withCheckedContinuation` 永久等待——
/// 这正是「点了下载没反应、进度条卡死」的根因之一。
final class StreamDownloader: NSObject, URLSessionDataDelegate {
    let dest: URL
    var resumeAt: Int64
    let onProgress: (Int64, Int64) -> Void
    var received: Int64 = 0
    var total: Int64 = 0
    var error: Error?
    var onComplete: (() -> Void)?
    private var fh: FileHandle?
    private weak var task: URLSessionDataTask?
    /// 连续无数据到达的上限（秒）。下载慢但持续有数据不触发；只有彻底停流才触发。
    private let stallTimeout: TimeInterval = 30
    private var stallTimer: DispatchSourceTimer?
    private var completed = false

    init(dest: URL, resumeAt: Int64, onProgress: @escaping (Int64, Int64) -> Void) {
        self.dest = dest
        self.resumeAt = resumeAt
        self.received = resumeAt   // 断点续传时进度从已有字节起算
        self.onProgress = onProgress
        super.init()
    }

    private func armStallWatchdog() {
        stallTimer?.cancel()
        stallTimer = nil
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + stallTimeout)
        t.setEventHandler { [weak self] in
            guard let self, !self.completed else { return }
            // 连续 30 秒没有任何数据 → 判为停滞，主动中断
            if self.error == nil {
                self.error = NSError(domain: "MS", code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "下载停滞：连续 \(Int(self.stallTimeout)) 秒无数据，已中断（可重试续传）"])
            }
            self.task?.cancel()
        }
        t.resume()
        stallTimer = t
    }

    private func stopWatchdog() {
        stallTimer?.cancel()
        stallTimer = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.task = dataTask
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
        armStallWatchdog()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        armStallWatchdog()   // 每收到一块数据就重置停滞计时
        do { try fh?.write(contentsOf: data) } catch { self.error = error }
        received += Int64(data.count)
        onProgress(received, total)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError err: Error?) {
        completed = true
        stopWatchdog()
        try? fh?.close()
        fh = nil
        if let err { self.error = err }
        onComplete?()
    }
}
