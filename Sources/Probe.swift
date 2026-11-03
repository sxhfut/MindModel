import Foundation
import Metal
import AppKit

struct Hardware {
    var chip: String = "未知"
    var model: String = "未知"
    var osVersion: String = "未知"
    var totalCores: Int = 0
    var perfCores: Int = 0
    var effCores: Int = 0
    var gpuName: String = "未知"
    var gpuCores: Int = 0
    var ramGB: Double = 0
    var metalWorkingSetGB: Double = 0
    var diskFreeGB: Double = 0
    var diskTotalGB: Double = 0
    var unified: Bool = true
}

enum Sh {
    @discardableResult
    static func run(_ launch: String, _ args: [String], timeout: Double = 25) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 需要退出码和 stderr 的场合（删除模型、注册失败原因）
    static func exec(_ launch: String, _ args: [String], timeout: Double = 120) -> (code: Int32, text: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "无法启动 \(launch)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    static func find(_ name: String) -> String? {
        let dirs = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin",
                    NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.ollama"]
        for d in dirs {
            let p = d + "/" + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
}

enum Probe {
    static func sysctlString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size + 1)
        guard sysctlbyname(key, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func sysctlInt(_ key: String) -> Int? {
        var v: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(key, &v, &size, nil, 0) == 0 else { return nil }
        return Int(v)
    }

    static func probe() -> Hardware {
        var h = Hardware()
        if let chip = sysctlString("machdep.cpu.brand_string") { h.chip = chip }
        if let m = sysctlString("hw.model") { h.model = m }
        let ov = ProcessInfo.processInfo.operatingSystemVersion
        h.osVersion = "macOS \(ov.majorVersion).\(ov.minorVersion).\(ov.patchVersion)"
        h.totalCores = sysctlInt("hw.ncpu") ?? ProcessInfo.processInfo.processorCount
        h.perfCores = sysctlInt("hw.perflevel0.physicalcpu") ?? 0
        h.effCores = sysctlInt("hw.perflevel1.physicalcpu") ?? 0
        if let mem = sysctlInt("hw.memsize") {
            h.ramGB = Double(mem) / 1_073_741_824.0
        }
        if let dev = MTLCreateSystemDefaultDevice() {
            h.gpuName = dev.name
            h.unified = dev.hasUnifiedMemory
            h.metalWorkingSetGB = Double(dev.recommendedMaxWorkingSetSize) / 1_073_741_824.0
        }
        let sp = Sh.run("/usr/sbin/system_profiler", ["SPDisplaysDataType"])
        for raw in sp.split(separator: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Total Number of Cores:") {
                let v = t.replacingOccurrences(of: "Total Number of Cores:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                h.gpuCores = Int(v) ?? 0
                break
            }
        }
        if let a = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let free = a[.systemFreeSize] as? NSNumber,
           let total = a[.systemSize] as? NSNumber {
            h.diskFreeGB = free.doubleValue / 1_073_741_824.0
            h.diskTotalGB = total.doubleValue / 1_073_741_824.0
        }
        return h
    }

    /// 实测统一内存的拷贝带宽（读+写计为 2 倍流量）。返回 GB/s。
    /// 这是本机经验值，不是厂商标称峰值；用于估算 decode 速度。
    static func measureBandwidth(sizeMB: Int = 1024, rounds: Int = 3) -> Double {
        let bytes = sizeMB * 1024 * 1024
        let src = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 64)
        let dst = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 64)
        defer { src.deallocate(); dst.deallocate() }
        memset(src, 0x5A, bytes)
        memset(dst, 0, bytes)
        let chunks = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let chunk = bytes / chunks
        guard chunk > 0 else { return 0 }

        // 预热
        DispatchQueue.concurrentPerform(iterations: chunks) { i in
            memcpy(dst.advanced(by: i * chunk), src.advanced(by: i * chunk), chunk)
        }

        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<rounds {
            DispatchQueue.concurrentPerform(iterations: chunks) { i in
                memcpy(dst.advanced(by: i * chunk), src.advanced(by: i * chunk), chunk)
            }
        }
        let ns = DispatchTime.now().uptimeNanoseconds - start
        guard ns > 0 else { return 0 }
        let gb = Double(bytes) * 2.0 * Double(rounds) / 1_073_741_824.0
        return gb / (Double(ns) / 1_000_000_000.0)
    }
}
