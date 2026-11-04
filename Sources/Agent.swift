import Foundation

// MARK: - 智能体（Agent）工具层
//
// 让本地模型不只是"聊天"，而是能动手：读文件、列目录、搜索、写文件、跑命令、联网。
// 实现上是 Ollama 的 function calling（/api/chat 的 tools 参数，OpenAI 风格）。
// 模型返回 tool_calls → 我们执行工具 → 把结果回传 → 循环，直到模型给出最终答复或步数用尽。

// 一条工具调用请求（模型产出）
struct ToolCall: Codable {
    var name: String
    var arguments: [String: String]
}

// 一条工具调用结果（我们回传）
struct ToolResult {
    var name: String
    var ok: Bool
    var output: String   // 成功时的结果或失败时的错误信息
}

/// 智能体每一步的可见记录：模型说了什么、调了什么工具、工具回了什么。
struct AgentStep: Identifiable {
    let id = UUID()
    enum Kind { case thought, tool, result, answer }
    var kind: Kind
    var title: String   // 工具名或"思考/答复"
    var detail: String  // 正文或工具输出
}

/// 内置工具清单。每个工具声明 name / 描述 / 参数 schema（OpenAI function 格式）。
/// 描述写清"什么时候用、返回什么"，模型才懂得按需调用。
enum AgentTools {

    static let definitions: [[String: Any]] = [
        funcDef(
            name: "read_file",
            desc: "读取一个文本文件的全部内容。用于查看代码、文档、配置。返回文件内容，文件不存在返回错误。",
            params: [
                ["name": "path", "type": "string", "description": "要读取的文件的绝对路径", "required": true],
                ["name": "max_chars", "type": "integer", "description": "最多返回多少字符，默认 20000，超长文件会截断", "required": false],
            ]
        ),
        funcDef(
            name: "list_dir",
            desc: "列出目录下的文件与子目录。用于了解目录结构。返回条目列表，可限制深度。",
            params: [
                ["name": "path", "type": "string", "description": "要列出的目录绝对路径", "required": true],
            ]
        ),
        funcDef(
            name: "search_files",
            desc: "按文件名关键字或文件内容搜索。返回匹配的文件路径列表。用于找某个文件或含某段代码的文件。",
            params: [
                ["name": "dir", "type": "string", "description": "在哪个目录下搜（绝对路径）", "required": true],
                ["name": "keyword", "type": "string", "description": "文件名或内容里要匹配的关键字", "required": true],
                ["name": "by_content", "type": "boolean", "description": "true 搜文件内容，false 只按文件名", "required": false],
            ]
        ),
        funcDef(
            name: "write_file",
            desc: "把内容写到一个文件（覆盖或新建）。用于生成代码、文档、报告。父目录不存在会自动创建。",
            params: [
                ["name": "path", "type": "string", "description": "要写入的文件绝对路径", "required": true],
                ["name": "content", "type": "string", "description": "要写入的完整内容", "required": true],
            ]
        ),
        funcDef(
            name: "run_command",
            desc: "执行一条 shell 命令并返回输出。用于编译、测试、git、数据处理等。命令会在用户确认后执行。",
            params: [
                ["name": "command", "type": "string", "description": "要执行的 shell 命令", "required": true],
                ["name": "cwd", "type": "string", "description": "工作目录，默认用户主目录", "required": false],
            ]
        ),
    ]

    private static func funcDef(name: String, desc: String, params: [[String: Any]]) -> [String: Any] {
        var props: [String: Any] = [:]
        var required: [String] = []
        for p in params {
            let key = p["name"] as! String
            var ps: [String: Any] = ["type": p["type"] as! String]
            if let d = p["description"] as? String { ps["description"] = d }
            props[key] = ps
            if (p["required"] as? Bool) == true { required.append(key) }
        }
        return [
            "type": "function",
            "function": [
                "name": name,
                "description": desc,
                "parameters": [
                    "type": "object",
                    "properties": props,
                    "required": required,
                ],
            ],
        ]
    }
}

/// 工具执行器。写文件与执行命令是"有副作用"的，调用前由 AppState 弹确认框。
/// 注意：当前没有路径白名单——模型可写任意绝对路径、执行任意 shell 命令，
/// 因此写/命令操作必须依赖上层的用户确认（confirmTool）来兜底，不能静默执行。
enum AgentExecutor {

    /// 执行一条工具调用，返回结果。
    /// 纯读操作（read/list/search）直接执行；写文件/命令由上层确认后再调用到这里。
    static func execute(_ call: ToolCall) -> ToolResult {
        switch call.name {
        case "read_file":
            return readFile(call.arguments)
        case "list_dir":
            return listDir(call.arguments)
        case "search_files":
            return searchFiles(call.arguments)
        case "write_file":
            return writeFile(call.arguments)
        case "run_command":
            return runCommand(call.arguments)
        default:
            return ToolResult(name: call.name, ok: false, output: "未知工具：\(call.name)")
        }
    }

    // MARK: 读

    private static func readFile(_ a: [String: String]) -> ToolResult {
        guard let path = a["path"], !path.isEmpty else {
            return ToolResult(name: "read_file", ok: false, output: "缺少 path 参数")
        }
        let maxChars = Int(a["max_chars"] ?? "") ?? 20000
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            return ToolResult(name: "read_file", ok: false, output: "文件不存在：\(path)")
        }
        guard let data = fm.contents(atPath: path) else {
            return ToolResult(name: "read_file", ok: false, output: "无法读取：\(path)（可能是二进制或权限不足）")
        }
        // 只当文本读，二进制给提示
        let text = String(decoding: data, as: UTF8.self)
        if text.contains("\u{0}") && text.count < 4 {
            return ToolResult(name: "read_file", ok: false, output: "\(path) 是二进制文件，大小 \(data.count) 字节，无法作为文本读取")
        }
        let out = text.count > maxChars ? String(text.prefix(maxChars)) + "\n…（截断，共 \(text.count) 字符）" : text
        return ToolResult(name: "read_file", ok: true, output: out)
    }

    private static func listDir(_ a: [String: String]) -> ToolResult {
        guard let path = a["path"], !path.isEmpty else {
            return ToolResult(name: "list_dir", ok: false, output: "缺少 path 参数")
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return ToolResult(name: "list_dir", ok: false, output: "目录不存在：\(path)")
        }
        do {
            let items = try fm.contentsOfDirectory(atPath: path).sorted()
            var lines: [String] = []
            for it in items.prefix(200) {
                let full = path + "/" + it
                var d: ObjCBool = false
                fm.fileExists(atPath: full, isDirectory: &d)
                let sz = d.boolValue ? 0 : (try? fm.attributesOfItem(atPath: full))?[.size] as? Int ?? 0
                lines.append(d.boolValue ? "📁 \(it)/" : "   \(it)（\(fmtSize(sz))）")
            }
            if items.count > 200 { lines.append("…（共 \(items.count) 项，只列前 200）") }
            return ToolResult(name: "list_dir", ok: true, output: lines.joined(separator: "\n"))
        } catch {
            return ToolResult(name: "list_dir", ok: false, output: "列目录失败：\(error.localizedDescription)")
        }
    }

    private static func searchFiles(_ a: [String: String]) -> ToolResult {
        guard let dir = a["dir"], !dir.isEmpty, let kw = a["keyword"], !kw.isEmpty else {
            return ToolResult(name: "search_files", ok: false, output: "需要 dir 和 keyword")
        }
        let byContent = (a["by_content"] == "true")
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return ToolResult(name: "search_files", ok: false, output: "目录不存在：\(dir)")
        }
        var hits: [String] = []
        // 跳过常见大目录，避免扫 node_modules、.git 等
        let skip = [".git", "node_modules", "build", "target", ".build", "DerivedData", ".venv", "__pycache__"]
        func walk(_ p: String, depth: Int) {
            if depth > 6 || hits.count >= 50 { return }
            guard let en = fm.enumerator(atPath: p) else { return }
            for case let rel as String in en {
                let name = (rel as NSString).lastPathComponent
                if skip.contains(name) {
                    en.skipDescendants()
                    continue
                }
                if byContent {
                    let full = p + "/" + rel
                    var d: ObjCBool = false
                    if fm.fileExists(atPath: full, isDirectory: &d), !d.boolValue, name.contains(".") {
                        if let content = try? String(contentsOfFile: full, encoding: .utf8),
                           content.localizedCaseInsensitiveContains(kw) {
                            hits.append(rel)
                        }
                    }
                } else if name.localizedCaseInsensitiveContains(kw) {
                    hits.append(rel)
                }
                if hits.count >= 50 { return }
            }
        }
        walk(dir, depth: 0)
        if hits.isEmpty {
            return ToolResult(name: "search_files", ok: true, output: "没找到匹配「\(kw)」的文件")
        }
        return ToolResult(name: "search_files", ok: true, output: hits.joined(separator: "\n"))
    }

    // MARK: 写 / 命令（有副作用）

    private static func writeFile(_ a: [String: String]) -> ToolResult {
        guard let path = a["path"], !path.isEmpty, let content = a["content"] else {
            return ToolResult(name: "write_file", ok: false, output: "需要 path 和 content")
        }
        do {
            let fm = FileManager.default
            let dir = (path as NSString).deletingLastPathComponent
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            let size = try fm.attributesOfItem(atPath: path)[.size] as? Int ?? 0
            return ToolResult(name: "write_file", ok: true, output: "已写入 \(path)（\(fmtSize(size))）")
        } catch {
            return ToolResult(name: "write_file", ok: false, output: "写入失败：\(error.localizedDescription)")
        }
    }

    private static func runCommand(_ a: [String: String]) -> ToolResult {
        guard let cmd = a["command"], !cmd.isEmpty else {
            return ToolResult(name: "run_command", ok: false, output: "缺少 command")
        }
        let cwd = a["cwd"] ?? NSHomeDirectory()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", cmd]
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.environment = ProcessInfo.processInfo.environment
        do {
            try p.run()
            p.waitUntilExit()
            let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            var text = o
            if !e.isEmpty { text += text.isEmpty ? e : "\n[stderr]\n" + e }
            if text.isEmpty { text = "（无输出，退出码 \(p.terminationStatus)）" }
            if text.count > 20000 { text = String(text.prefix(20000)) + "\n…（截断）" }
            return ToolResult(name: "run_command", ok: p.terminationStatus == 0,
                              output: text)
        } catch {
            return ToolResult(name: "run_command", ok: false, output: "执行失败：\(error.localizedDescription)")
        }
    }

    private static func fmtSize(_ n: Int) -> String {
        if n >= 1024 * 1024 { return String(format: "%.1f MB", Double(n) / 1048576) }
        if n >= 1024 { return String(format: "%.1f KB", Double(n) / 1024) }
        return "\(n) B"
    }
}
