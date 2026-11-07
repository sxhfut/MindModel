import Foundation

struct GGUFInfo {
    var fileName = ""
    var path = ""
    var arch = "?"
    var modelName = "?"
    var quant = "?"
    var paramsB: Double = 0
    var fileGB: Double = 0
    var contextLength: Int = 0
    var blockCount: Int = 0
    var headCountKV: Int = 0
    var headCount: Int = 0
    var embeddingLength: Int = 0
    var tensorCount = 0
    var kv1k: Double = 0
    var paramsEstimated = false     // 未能读到张量表时按体积反推
    var truncated = false           // 头部元数据不完整
    var splitCount = 1              // 分片总数
    var splitNo = 0                 // 本片序号（1 起）
    var hasVision = false           // 含视觉编码器
    var isProjector = false         // 本文件是 mmproj 投影器，不是主模型
    var hasChatTemplate = false
}

/// 饱和转换：坏掉的 GGUF 头里可能写着天文数字或 NaN。
/// Swift 的 `Int(Double)` / `Int(UInt64)` 在这种值上是**陷阱指令**（直接 crash），
/// 不是返回 nil——导入一个下崩的文件就会把整个应用带走，所以一律走这两个函数。
@inline(__always) private func satInt(_ d: Double) -> Int {
    if d.isNaN { return 0 }
    if d >= 9.2e18 { return Int.max }
    if d <= -9.2e18 { return Int.min }
    return Int(d)
}

@inline(__always) private func satInt(_ u: UInt64) -> Int {
    u > UInt64(Int.max) ? Int.max : Int(u)
}

/// 只接受落在 (0, upTo] 的整数值；NaN、负数、天文数字一律归 0（当作没读到）
@inline(__always) private func sane(_ d: Double, upTo: Int) -> Int {
    guard d > 0, d <= Double(upTo) else { return 0 }
    return Int(d)
}

/// 只读 GGUF 头部：魔数 → 版本 → KV 表 → 张量信息表。
/// 关键点：数组必须按真实元素个数跳过，不能截断，否则后续全部错位。
enum GGUF {
    private struct Reader {
        let d: Data
        var off = 0
        var bad = false

        mutating func need(_ n: Int) -> Bool {
            if n < 0 || off + n > d.count { bad = true; return false }
            return true
        }
        mutating func u32() -> UInt32 {
            guard need(4) else { return 0 }
            var v: UInt32 = 0
            withUnsafeMutableBytes(of: &v) { _ = d.copyBytes(to: $0, from: off..<(off + 4)) }
            off += 4
            return v
        }
        mutating func u64() -> UInt64 {
            guard need(8) else { return 0 }
            var v: UInt64 = 0
            withUnsafeMutableBytes(of: &v) { _ = d.copyBytes(to: $0, from: off..<(off + 8)) }
            off += 8
            return v
        }
        mutating func skip(_ n: Int) {
            if n < 0 || off + n > d.count { bad = true; off = min(off, d.count); return }
            off += n
        }
        mutating func str() -> String {
            let n = u64()
            guard !bad, n < 8_000_000 else { return "" }
            let len = Int(n)
            guard need(len) else { return "" }
            let s = String(decoding: d[off..<(off + len)], as: UTF8.self)
            off += len
            return s
        }
        mutating func skipStr() {
            let n = u64()
            guard !bad, n < 200_000_000 else { return }
            skip(Int(n))
        }
        func width(_ t: UInt32) -> Int {
            switch t {
            case 0, 1, 7: return 1
            case 2, 3: return 2
            case 4, 5, 6: return 4
            case 10, 11, 12: return 8
            default: return -1
            }
        }
        mutating func num(_ t: UInt32) -> Double {
            switch t {
            case 0: let v = d[safe: off]; skip(1); return Double(v)
            case 1: let v = d[safe: off]; skip(1); return Double(Int8(bitPattern: v))
            case 2: guard need(2) else { return 0 }
                    var v: UInt16 = 0; withUnsafeMutableBytes(of: &v) { _ = d.copyBytes(to: $0, from: off..<(off + 2)) }; skip(2); return Double(v)
            case 3: guard need(2) else { return 0 }
                    var v: Int16 = 0; withUnsafeMutableBytes(of: &v) { _ = d.copyBytes(to: $0, from: off..<(off + 2)) }; skip(2); return Double(v)
            case 4: return Double(u32())
            case 5: return Double(Int32(bitPattern: u32()))
            case 6: guard need(4) else { return 0 }
                    var v: Float32 = 0; withUnsafeMutableBytes(of: &v) { _ = d.copyBytes(to: $0, from: off..<(off + 4)) }; skip(4); return Double(v)
            case 7: let v = d[safe: off]; skip(1); return Double(v)
            case 10: return Double(u64())
            case 11: return Double(Int64(bitPattern: u64()))
            case 12: guard need(8) else { return 0 }
                     var v: Double = 0; withUnsafeMutableBytes(of: &v) { _ = d.copyBytes(to: $0, from: off..<(off + 8)) }; skip(8); return v
            default:
                skipValue(t)
                return 0
            }
        }
        mutating func skipValue(_ t: UInt32) {
            switch t {
            case 8:
                skipStr()
            case 9:
                let et = u32()
                let n = u64()
                guard !bad, n < 50_000_000 else { bad = true; return }
                let w = width(et)
                if w > 0 {
                    skip(Int(n) * w)          // 定长数组一次跳过
                } else {
                    for _ in 0..<Int(n) {
                        skipValue(et)          // 字符串数组逐个跳过（不分配字符串）
                        if bad { return }
                    }
                }
            default:
                let w = width(t)
                if w > 0 { skip(w) } else { bad = true }
            }
        }
    }

    /// ggml 文件类型 → 量化名（与 llama.cpp 的枚举一致）
    static func quantName(_ v: Double) -> String {
        switch satInt(v) {
        case 0: return "F32"
        case 1: return "F16"
        case 2: return "Q4_0"
        case 3: return "Q4_1"
        case 7: return "Q8_0"
        case 8: return "Q5_0"
        case 9: return "Q5_1"
        case 10: return "Q2_K"
        case 11: return "Q3_K_S"
        case 12: return "Q3_K_M"
        case 13: return "Q3_K_L"
        case 14: return "Q4_K_S"
        case 15: return "Q4_K_M"
        case 16: return "Q5_K_S"
        case 17: return "Q5_K_M"
        case 18: return "Q6_K"
        case 19: return "IQ2_XXS"
        case 20: return "IQ2_XS"
        case 24: return "IQ1_S"
        case 25: return "IQ4_NL"
        case 28: return "IQ2_S"
        case 29: return "IQ2_M"
        case 30: return "IQ4_XS"
        case 31: return "IQ1_M"
        case 32: return "BF16"
        default: return "type\(satInt(v))"
        }
    }

    /// 量化 → 每参数比特数（仅用于反推参数量）
    static func bitsPerParam(_ q: String) -> Double {
        let u = q.uppercased()
        if u.contains("BF16") || u.contains("F16") { return 16 }
        if u.contains("F32") { return 32 }
        if u.contains("Q8") { return 8.5 }
        if u.contains("Q6") { return 6.6 }
        if u.contains("Q5") { return 5.6 }
        if u.contains("Q4") { return 4.6 }
        if u.contains("Q3") { return 3.9 }
        if u.contains("Q2") { return 3.0 }
        return 5.0
    }

    static func parse(path: String) -> GGUFInfo? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let sizeNum = attrs[.size] as? NSNumber else { return nil }
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }

        // 头部元数据（含分词表）通常几 MB，读 64 MB 足够；读不到就退化为估算
        let head = try? fh.read(upToCount: 64 * 1024 * 1024)
        guard let data = head, data.count >= 24 else { return nil }

        var info = GGUFInfo()
        info.path = path
        info.fileName = (path as NSString).lastPathComponent
        info.fileGB = sizeNum.doubleValue / 1_073_741_824.0

        var r = Reader(d: data)
        guard r.u32() == 0x4655_4747 else { return nil }   // "GGUF"
        let version = r.u32()
        guard version >= 2, version <= 4 else { return nil }
        let tensorCount = satInt(r.u64())
        let kvCount = satInt(r.u64())
        guard !r.bad, kvCount > 0, kvCount < 100_000, tensorCount >= 0, tensorCount < 2_000_000 else { return nil }

        for _ in 0..<kvCount {
            let key = r.str()
            let t = r.u32()
            if r.bad { info.truncated = true; break }
            let watched = key == "general.architecture" || key == "general.name"
                || key == "general.file_type"
                || key == "split.count" || key == "split.no"
                || key == "clip.has_vision_encoder" || key == "tokenizer.chat_template"
                || key.hasSuffix(".block_count") || key.hasSuffix(".context_length")
                || key.hasSuffix(".attention.head_count_kv") || key.hasSuffix(".attention.head_count")
                || key.hasSuffix(".embedding_length")
            if watched {
                if t == 8 {
                    let s = r.str()
                    if key == "general.architecture" { info.arch = s }
                    if key == "general.name" { info.modelName = s }
                    if key == "tokenizer.chat_template" { info.hasChatTemplate = !s.isEmpty }
                } else {
                    let v = r.num(t)
                    // 只接受物理上说得通的值：饱和转换会把 1e300 钳成 Int.max，
                    // 那会变成「上下文 9.2e18」这种荒谬数字，超范围一律当没读到。
                    switch true {
                    case key == "general.file_type": info.quant = quantName(v)
                    case key.hasSuffix(".block_count"): info.blockCount = sane(v, upTo: 10_000)
                    case key.hasSuffix(".context_length"): info.contextLength = sane(v, upTo: 10_000_000)
                    case key.hasSuffix(".attention.head_count_kv"): info.headCountKV = sane(v, upTo: 10_000)
                    case key.hasSuffix(".attention.head_count"): info.headCount = sane(v, upTo: 10_000)
                    case key.hasSuffix(".embedding_length"): info.embeddingLength = sane(v, upTo: 10_000_000)
                    case key == "split.count": info.splitCount = max(1, sane(v, upTo: 100))
                    case key == "split.no": info.splitNo = min(sane(v, upTo: 100), 100)
                    case key == "clip.has_vision_encoder": info.hasVision = v > 0
                    default: break
                    }
                }
            } else {
                r.skipValue(t)
            }
            if r.bad { info.truncated = true; break }
        }

        // 张量信息表：参数量 = 各张量维度连乘之和
        if !r.bad && tensorCount > 0 {
            var params: Double = 0
            var counted = 0
            for _ in 0..<tensorCount {
                let nm = r.str()
                if r.bad || nm.isEmpty { break }
                let nDims = r.u32()
                if r.bad { break }
                guard nDims > 0, nDims <= 8 else { break }
                var prod: UInt64 = 1
                for _ in 0..<nDims {
                    let dim = r.u64()
                    if r.bad { break }
                    let (p, ovf) = prod.multipliedReportingOverflow(by: dim)
                    prod = ovf ? UInt64.max / 8 : p
                }
                _ = r.u32()   // ggml dtype
                _ = r.u64()   // 数据偏移
                if r.bad { break }
                params += Double(prod)
                counted += 1
            }
            info.tensorCount = counted
            if counted == tensorCount && params > 0 {
                info.paramsB = params / 1_000_000_000.0
            } else if counted > 0 && params > 0 {
                // 部分张量（头部被截断）：按已读张量均值外推
                info.paramsB = params / Double(counted) * Double(tensorCount) / 1_000_000_000.0
                info.paramsEstimated = true
            }
        }

        if info.quant == "?" {
            let l = info.fileName.lowercased()
            for q in ["q4_k_m", "q4_k_s", "q5_k_m", "q5_k_s", "q6_k", "q8_0", "q4_0", "q3_k_m", "q2_k", "bf16", "f16"] {
                if l.contains(q) { info.quant = q.uppercased(); break }
            }
        }
        if info.paramsB <= 0, info.fileGB > 0 {
            info.paramsB = info.fileGB * 8.0 / bitsPerParam(info.quant)
            info.paramsEstimated = true
        }

        // 投影器 / 视觉 / 分片 的兜底判定（真实 GGUF 常不带 split.* 键）
        let low = info.fileName.lowercased()
        if info.arch == "clip" || low.contains("mmproj") {
            info.isProjector = true
            info.hasVision = true
        }
        if info.splitCount <= 1, let sp = splitToken(low) {
            info.splitNo = sp.no
            info.splitCount = sp.count
        }

        // KV cache：2(K/V) × 层数 × KV头数 × head_dim × 2 字节(f16)
        if info.blockCount > 0, info.headCountKV > 0,
           info.embeddingLength > 0, info.headCount > 0 {
            let headDim = Double(info.embeddingLength) / Double(max(1, info.headCount))
            let perToken = 2.0 * Double(info.blockCount) * Double(info.headCountKV) * headDim * 2.0
            info.kv1k = perToken * 1024.0 / 1_073_741_824.0
        } else if info.fileGB > 0 {
            info.kv1k = info.fileGB * 0.012   // 兜底：按体积经验系数
        }
        return info
    }
}

extension Data {
    subscript(safe i: Int) -> UInt8 { i >= 0 && i < count ? self[i] : 0 }
}

// MARK: - 文件名里的分片标记

struct SplitToken { let prefix: String; let no: Int; let count: Int }

/// 解析 "xxx-00002-of-00003.gguf" → (prefix "xxx", no 2, count 3)
func splitToken(_ fileName: String) -> SplitToken? {
    guard let r = fileName.range(of: #"-\d{5}-of-\d{5}"#, options: [.regularExpression, .caseInsensitive]) else {
        return nil
    }
    let token = String(fileName[r]).dropFirst()          // "00002-of-00003"
    let parts = token.split(separator: "-")
    guard parts.count == 3,
          let no = Int(parts[0]), let cnt = Int(parts[2]), cnt > 1 else { return nil }
    return SplitToken(prefix: String(fileName[..<r.lowerBound]), no: no, count: cnt)
}
