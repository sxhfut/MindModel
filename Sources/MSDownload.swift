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

/// 线程安全的进度累加器。分段/多文件并发下载时，各连接从不同线程回调进度，
/// 这里用 actor 串行化累加，再把聚合后的总量交给 onProgress（可安全跨线程调用）。
actor ProgressMeter {
    private let total: Int64
    private var buckets: [Int: Int64] = [:]
    private let onProgress: (Int64, Int64) -> Void

    init(total: Int64, onProgress: @escaping (Int64, Int64) -> Void) {
        self.total = total
        self.onProgress = onProgress
    }

    /// 更新某个 bucket 的进度，并回调聚合总量。
    func report(_ key: Int, received: Int64) {
        buckets[key] = received
        let sum = buckets.values.reduce(0, +)
        onProgress(sum, total)
    }
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
        guard let url = directURL(org: org, name: name, filePath: filePath) else {
            throw NSError(domain: "MS", code: -1, userInfo: [NSLocalizedDescriptionKey: "下载地址无效"])
        }
        let saveName = (filePath as NSString).lastPathComponent
        return try await download(url: url, saveName: saveName, to: dir, onProgress: onProgress)
    }

    /// 构造魔搭直链 URL（供下载与持久化记录复用）。
    static func directURL(org: String, name: String, filePath: String) -> URL? {
        // FilePath 是 query 参数，用 urlQueryAllowed 转义（含 / 等字符），避免路径被截断
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "/+&=")
        let enc = filePath.addingPercentEncoding(withAllowedCharacters: allowed) ?? filePath
        let orgEnc = org.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? org
        let nameEnc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let urlStr = "\(host)/\(orgEnc)/\(nameEnc)/repo?Revision=master&FilePath=\(enc)"
        return URL(string: urlStr)
    }

    /// 通用直链流式下载（魔搭与 HuggingFace 直链共用）。
    /// 自动路由：文件较小时走单连接（简单可靠）；较大时用多线程分段并发下载。
    /// 内置断点续传 + 自动重试 + 停滞看门狗。
    static func download(url: URL, saveName: String, to dir: URL,
                         onProgress: @escaping (Int64, Int64) -> Void,
                         maxRetries: Int = 8) async throws -> URL {
        // 先探测文件总大小，决定是否走多线程分段
        if let total = await probeSize(url: url), total > segmentThreshold {
            return try await downloadSegmented(url: url, saveName: saveName, total: total, to: dir, onProgress: onProgress)
        }
        return try await downloadSingle(url: url, saveName: saveName, to: dir, onProgress: onProgress, maxRetries: maxRetries)
    }

    /// 单连接流式下载（小文件 / 服务器不支持 Range 时的回退）。
    /// 内置断点续传 + 自动重试：直链（尤其魔搭）常中途断流，这里会把「没下满」的
    /// 情况自动重连续传，最多 maxRetries 轮，而不是让调用方拿到半个文件。
    static func downloadSingle(url: URL, saveName: String, to dir: URL,
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

    /// 超过此大小（字节）才启用多线程分段下载。默认 200 MB。
    /// 小于它走单连接更省事（避免分片合并开销与 Range 探测）。
    /// 用 static var 以便测试时可临时调低阈值强制走分段路径。
    static var segmentThreshold: Int64 = 200 * 1_048_576

    /// 分段并发数。魔搭/HF 直链对单 IP 并发连接有限制，8 段在多数网络下已接近带宽上限。
    static var segmentCount: Int = 8

    /// 探测远端文件总大小（发一个 Range: bytes=0-0 请求，读 Content-Range 的 total）。
    /// 服务器不支持 Range 时返回 nil，调用方回退单连接。
    static func probeSize(url: URL) async -> Int64? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse {
                if let r = http.value(forHTTPHeaderField: "Content-Range"),
                   let last = r.split(separator: "/").last, let t = Int64(last) {
                    return t
                }
                // 服务器忽略 Range 返回 200：读 Content-Length
                if let l = http.value(forHTTPHeaderField: "Content-Length"), let t = Int64(l) {
                    return t
                }
            }
        } catch { /* 探测失败就回退单连接 */ }
        return nil
    }

    /// 多线程分段并发下载：把文件切成 segmentCount 段，各自用 Range 并发下载到临时分片，
    /// 全部完成后按顺序合并成最终文件。任一一段失败则整体重试（保留已完成的段）。
    static func downloadSegmented(url: URL, saveName: String, total: Int64, to dir: URL,
                                  onProgress: @escaping (Int64, Int64) -> Void,
                                  maxRetries: Int = 4) async throws -> URL {
        let dest = dir.appendingPathComponent(saveName)

        // 若最终文件已完整，直接返回（幂等）
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
           let sz = attrs[.size] as? Int64, sz == total {
            onProgress(total, total)
            return dest
        }

        // 分片临时目录：dest 同名 + ".parts"
        let partsDir = dir.appendingPathComponent("\(saveName).parts", isDirectory: true)
        try? FileManager.default.createDirectory(at: partsDir, withIntermediateDirectories: true)

        for _ in 0...maxRetries {
            if Task.isCancelled { throw CancellationError() }

            // 计算段边界
            let n = segmentCount
            let seg = total / Int64(n)
            var ranges: [(Int, Int64, Int64)] = []   // (index, from, to) 闭区间
            for i in 0..<n {
                let from = Int64(i) * seg
                let to = (i == n - 1) ? (total - 1) : (from + seg - 1)
                ranges.append((i, from, to))
            }

            // 全局进度聚合（actor 线程安全）
            let meter = ProgressMeter(total: total, onProgress: onProgress)

            do {
                try await withThrowingTaskGroup(of: Error?.self) { group in
                    for (idx, from, to) in ranges {
                        group.addTask {
                            if Task.isCancelled { return CancellationError() }
                            let part = partsDir.appendingPathComponent("part-\(idx)")
                            // 该段已下完则跳过
                            if let a = try? FileManager.default.attributesOfItem(atPath: part.path),
                               let sz = a[.size] as? Int64, sz == (to - from + 1) {
                                await meter.report(idx, received: sz)
                                return nil
                            }
                            let err = await downloadRange(url: url, from: from, to: to, part: part) { recv in
                                Task { await meter.report(idx, received: recv) }
                            }
                            return err
                        }
                    }
                    // 收集结果：任一失败即抛错，触发外层重试
                    for try await err in group {
                        if let err { throw err }
                    }
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                // 分段失败 → 稍候重试（保留已下完的段）
                try await Task.sleep(nanoseconds: 1_500_000_000)
                continue
            }

            // 所有段完成 → 合并
            if let err = merge(parts: partsDir, ranges: ranges.map { ($0.0, $0.1) }, to: dest, total: total) {
                throw err
            }
            // 合并成功，清理分片目录
            try? FileManager.default.removeItem(at: partsDir)
            onProgress(total, total)
            return dest
        }

        throw NSError(domain: "MS", code: -2,
                      userInfo: [NSLocalizedDescriptionKey: "分段下载多次失败，仍未完成（已保留部分，可重试）"])
    }

    /// 下载单个 Range 段到分片文件。返回错误（nil 表示成功）。
    /// 复用 StreamDownloader（含停滞看门狗），支持该段内部的断点续传。
    static func downloadRange(url: URL, from: Int64, to: Int64, part: URL,
                              onPartProgress: @escaping (Int64) -> Void) async -> Error? {
        // 该段已存在的字节（断点续传）
        var resume: Int64 = 0
        if let a = try? FileManager.default.attributesOfItem(atPath: part.path),
           let sz = a[.size] as? Int64, sz > 0 {
            resume = sz
        }
        let segLen = to - from + 1
        if resume >= segLen {
            onPartProgress(segLen)
            return nil
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 60
        req.setValue("bytes=\(from + resume)-\(to)", forHTTPHeaderField: "Range")

        let streamer = StreamDownloader(dest: part, resumeAt: resume) { recv, _ in
            onPartProgress(recv)
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 0
        let session = URLSession(configuration: config, delegate: streamer, delegateQueue: nil)

        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                streamer.onComplete = { cont.resume() }
                session.dataTask(with: req).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
        session.invalidateAndCancel()

        if Task.isCancelled { return CancellationError() }
        if let e = streamer.error { return e }
        // 校验该段是否下满
        let got = streamer.received
        if got >= segLen { return nil }
        return NSError(domain: "MS", code: -4,
                       userInfo: [NSLocalizedDescriptionKey: "分段未下满（\(got)/\(segLen)）"])
    }

    /// 把各分片按顺序合并到最终文件。返回错误（nil 表示成功）。
    /// 用流式拷贝（分块读入）避免把整段几百 MB 读进内存导致 OOM。
    static func merge(parts: URL, ranges: [(index: Int, from: Int64)], to dest: URL, total: Int64) -> Error? {
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            FileManager.default.createFile(atPath: dest.path, contents: nil)
            let out = try FileHandle(forWritingTo: dest)
            defer { try? out.close() }
            for (idx, _) in ranges.sorted(by: { $0.index < $1.index }) {
                let p = parts.appendingPathComponent("part-\(idx)")
                guard FileManager.default.fileExists(atPath: p.path),
                      let fin = FileHandle(forReadingAtPath: p.path) else {
                    return NSError(domain: "MS", code: -5,
                                   userInfo: [NSLocalizedDescriptionKey: "合并时缺失分片 part-\(idx)"])
                }
                defer { try? fin.close() }
                // 分块流式拷贝，每块 8 MB，避免大段整读进内存
                while true {
                    let chunk = fin.readData(ofLength: 8 * 1_048_576)
                    if chunk.isEmpty { break }
                    try out.write(contentsOf: chunk)
                }
            }
            try out.synchronize()
            return nil
        } catch {
            return error
        }
    }
}

// MARK: - 下载记录持久化（断点续传）

/// 一次下载任务的持久化记录。用于应用重启后识别磁盘上的半截文件并提供「继续下载」。
/// 关键：半截文件本身不知道原始总大小，所以必须把 totalSize 与远端地址一起落盘。
struct DownloadRecord: Codable, Identifiable, Equatable {
    var id: String { fileName }
    /// 本地保存的文件名（不含目录）
    let fileName: String
    /// 远端直链 URL（重新下载/续传用）
    let remoteURL: String
    /// 文件总大小（字节）
    let totalSize: Int64
    /// 来源：ms / hf
    let source: String
    /// 创建时间戳（Unix 秒）
    let createdAt: Int64

    /// 磁盘上已下载的字节数（含 .parts 分片累计），由检测函数实时计算，不持久化
    var downloadedBytes: Int64 {
        // 单文件直下
        if let a = try? FileManager.default.attributesOfItem(atPath: localPath.path),
           let sz = a[.size] as? Int64 {
            return sz
        }
        // 分段下载：累计 .parts 各分片
        var sum: Int64 = 0
        let parts = localPartsDir
        if let names = try? FileManager.default.contentsOfDirectory(atPath: parts.path) {
            for n in names {
                let p = parts.appendingPathComponent(n)
                if let a = try? FileManager.default.attributesOfItem(atPath: p.path),
                   let sz = a[.size] as? Int64 {
                    sum += sz
                }
            }
        }
        return sum
    }

    /// 续传进度 0~1
    var progress: Double {
        totalSize > 0 ? min(1.0, Double(downloadedBytes) / Double(totalSize)) : 0
    }

    var percentText: String {
        String(format: "%.0f%%", progress * 100)
    }

    /// 是否已完整（无需续传）
    var isComplete: Bool { downloadedBytes >= totalSize }

    var localPath: URL {
        DownloadRecord.downloadDir.appendingPathComponent(fileName)
    }

    var localPartsDir: URL {
        DownloadRecord.downloadDir.appendingPathComponent("\(fileName).parts", isDirectory: true)
    }

    /// 下载目录（与 AppState.downloadDir 一致，但此处非隔离可同步调用）。
    static let downloadDir: URL = {
        let dl = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = dl.appendingPathComponent("MindModel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    var remote: URL? { URL(string: remoteURL) }
}

/// 下载记录的存取。UserDefaults key mm.downloads。
enum DownloadStore {
    static let key = "mm.downloads"

    static func load() -> [DownloadRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([DownloadRecord].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [DownloadRecord]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func upsert(_ rec: DownloadRecord) {
        var list = load()
        list.removeAll { $0.id == rec.id }
        list.append(rec)
        save(list)
    }

    static func remove(_ fileName: String) {
        var list = load()
        list.removeAll { $0.id == fileName }
        save(list)
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
