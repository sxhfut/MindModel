//! MindModel 浏览器兜底壳：本地 HTTP 服务。
//!
//! 无 GUI 平台（麒麟/统信、龙芯、海光、服务器）的兜底路径：
//! `mindmodel-serve` 起一个本地 HTTP 服务，浏览器打开 http://127.0.0.1:8462
//! 即可看到与桌面版同一套前端（`ui/`），所有算法仍在本地 Rust 侧跑。
//!
//! 设计原则：
//! - 零外部依赖：HTTP 用 std::net::TcpListener，JSON 手写序列化。
//! - 与 Tauri 壳（shells/tauri/src-tauri/src/lib.rs）暴露同一套数据形状，
//!   前端 ui/src/main.js 无需感知是桌面还是浏览器。
//! - 只监听 127.0.0.1，不对外网开放，避免暴露本机探测信息。

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;

use mindmodel_backend;
use mindmodel_core::advisor::{Advisor, FitLevel, Purpose};
use mindmodel_core::capability::capability_of;
use mindmodel_core::task::{TaskBlend, WorkTask};
use mindmodel_core::{self, MODELS};

const DEFAULT_PORT: u16 = 8462;

fn main() {
    let port: u16 = std::env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(DEFAULT_PORT);

    let listener = TcpListener::bind(("127.0.0.1", port))
        .unwrap_or_else(|e| {
            eprintln!("无法监听 127.0.0.1:{port}：{e}");
            std::process::exit(1);
        });

    println!("MindModel 浏览器兜底壳已启动");
    println!("  打开浏览器访问  http://127.0.0.1:{port}");
    println!("  按 Ctrl+C 退出");
    println!("  （只监听本机回环地址，不对外网开放）");

    for stream in listener.incoming() {
        match stream {
            Ok(s) => {
                std::thread::spawn(|| handle(s));
            }
            Err(e) => eprintln!("连接错误：{e}"),
        }
    }
}

fn handle(mut stream: TcpStream) {
    let mut buf = [0u8; 8192];
    let n = match stream.read(&mut buf) {
        Ok(n) => n,
        Err(_) => return,
    };
    let req = String::from_utf8_lossy(&buf[..n]);
    let (method, path) = parse_request(&req);
    let (status, ct, body) = route(&method, &path);
    let resp = format!(
        "HTTP/1.1 {status}\r\nContent-Type: {ct}; charset=utf-8\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body.len(),
        body
    );
    let _ = stream.write_all(resp.as_bytes());
}

fn parse_request(req: &str) -> (String, String) {
    let mut lines = req.lines();
    let first = lines.next().unwrap_or("");
    let mut parts = first.split_whitespace();
    let method = parts.next().unwrap_or("GET").to_string();
    let path = parts.next().unwrap_or("/").to_string();
    (method, path)
}

/// 路径可能带 query（/api/advise?purpose=writing）。这里把 query 拆出来返回。
fn split_query(path: &str) -> (&str, String) {
    match path.split_once('?') {
        Some((p, q)) => (p, q.to_string()),
        None => (path, String::new()),
    }
}

fn route(method: &str, path: &str) -> (&'static str, &'static str, String) {
    if method == "OPTIONS" {
        return ("204 No Content", "text/plain", String::new());
    }
    let (p, query) = split_query(path);
    match p {
        "/api/scan" => ("200 OK", "application/json", scan_json()),
        "/api/engines" => ("200 OK", "application/json", engines_json()),
        "/api/models" => ("200 OK", "application/json", models_json()),
        "/api/advise" => ("200 OK", "application/json", advise_json(&query)),
        "/api/task" => ("200 OK", "application/json", task_json(&query)),
        "/api/health" => ("200 OK", "application/json", r#"{"ok":true,"name":"mindmodel-serve"}"#.to_string()),
        "/" | "/index.html" => serve_static("index.html"),
        _ => serve_static(p.trim_start_matches('/')),
    }
}

/// 找到 ui/dist 目录（从 server 二进制所在位置向上找），返回其绝对路径。
fn find_dist_dir() -> Option<PathBuf> {
    // 1. 显式环境变量优先
    if let Ok(d) = std::env::var("MM_UI_DIST") {
        let p = PathBuf::from(d);
        if p.is_dir() {
            return Some(p);
        }
    }
    // 2. 从当前目录向上找 ui/dist（cargo run 时 cwd 是 rust/）
    let mut dir = std::env::current_dir().ok()?;
    for _ in 0..6 {
        let cand = dir.join("ui").join("dist");
        if cand.is_dir() {
            return Some(cand);
        }
        if !dir.pop() {
            break;
        }
    }
    // 3. 从可执行文件位置向上找（发布版二进制在 rust/target/release/）
    if let Ok(exe) = std::env::current_exe() {
        let mut d = exe;
        d.pop(); // 去掉文件名
        for _ in 0..8 {
            let cand = d.join("ui").join("dist");
            if cand.is_dir() {
                return Some(cand);
            }
            if !d.pop() {
                break;
            }
        }
    }
    None
}

/// 服务 ui/dist 里的静态文件；找不到则回退到一段内联说明页。
fn serve_static(rel: &str) -> (&'static str, &'static str, String) {
    if let Some(dist) = find_dist_dir() {
        // 防目录穿越：规范化后必须仍在 dist 内
        let target = dist.join(rel);
        if let (Ok(canon), Ok(base)) = (target.canonicalize(), dist.canonicalize()) {
            if canon.starts_with(&base) && canon.is_file() {
                let bytes = match std::fs::read(&canon) {
                    Ok(b) => b,
                    Err(_) => return ("404 Not Found", "application/json", r#"{"error":"read failed"}"#.to_string()),
                };
                let ct = content_type(rel);
                // 文本类文件按 UTF-8 读；二进制（png 等）按字节原样返回，避免丢字节
                let body = if ct.starts_with("image/") || ct == "application/octet-stream" {
                    bytes.iter().map(|&b| b as char).collect()
                } else {
                    String::from_utf8_lossy(&bytes).to_string()
                };
                return ("200 OK", ct, body);
            }
        }
    }
    if rel == "index.html" || rel.is_empty() {
        ("200 OK", "text/html", fallback_html())
    } else {
        ("404 Not Found", "application/json", r#"{"error":"not found"}"#.to_string())
    }
}

fn content_type(rel: &str) -> &'static str {
    if rel.ends_with(".html") || rel.ends_with(".htm") {
        "text/html"
    } else if rel.ends_with(".js") {
        "application/javascript"
    } else if rel.ends_with(".css") {
        "text/css"
    } else if rel.ends_with(".svg") {
        "image/svg+xml"
    } else if rel.ends_with(".png") {
        "image/png"
    } else if rel.ends_with(".json") {
        "application/json"
    } else {
        "application/octet-stream"
    }
}

fn fallback_html() -> String {
    r#"<!DOCTYPE html>
<html lang="zh">
<head><meta charset="utf-8"><title>MindModel</title></head>
<body style="font-family:system-ui;max-width:720px;margin:48px auto;padding:0 24px;line-height:1.7">
<h1>MindModel</h1>
<p>浏览器兜底壳已运行，但前端静态文件未找到。请先构建前端：</p>
<pre>cd ui && npm install && npm run build</pre>
<p>然后重启 <code>mindmodel-serve</code>。也可以直接调用 API：</p>
<ul>
<li><a href="/api/scan">/api/scan</a> — 硬件体检</li>
<li><a href="/api/engines">/api/engines</a> — 推理后端</li>
<li><a href="/api/models">/api/models</a> — 模型清单</li>
<li><a href="/api/advise?purpose=writing">/api/advise?purpose=writing</a> — 按用途推荐</li>
<li><a href="/api/task?tasks=paper,code">/api/task?tasks=paper,code</a> — 按任务推荐</li>
</ul>
</body></html>"#.to_string()
}

// —— JSON 序列化（手写，零依赖）——

fn esc(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

fn scan_json() -> String {
    let h = mindmodel_probe::probe();
    let bw = mindmodel_probe::measure_bandwidth(1024, 3);
    let budget = h.budget_gb();
    let a = Advisor::new(budget, bw, 16384);
    let fit = MODELS.iter().filter(|m| a.level(m) != FitLevel::TooHeavy).count();
    format!(
        r#"{{"chip":"{}","machine_model":"{}","os":"{}","total_cores":{},"perf_cores":{},"eff_cores":{},"gpu_name":"{}","gpu_cores":{},"ram_gb":{},"working_set_gb":{},"unified_memory":{},"disk_free_gb":{},"disk_total_gb":{},"budget_gb":{},"bandwidth":{},"fit_count":{},"total_models":{},"provenance":"{}"}}"#,
        esc(&h.chip),
        esc(&h.machine_model),
        esc(&h.os),
        h.total_cores,
        h.perf_cores,
        h.eff_cores,
        esc(&h.gpu_name),
        h.gpu_cores,
        h.ram_gb,
        h.working_set_gb,
        h.unified_memory,
        h.disk_free_gb,
        h.disk_total_gb,
        budget,
        bw,
        fit,
        MODELS.len(),
        esc(&h.provenance),
    )
}

fn engines_json() -> String {
    let items: Vec<String> = mindmodel_backend::detect_all()
        .into_iter()
        .map(|b| {
            format!(
                r#"{{"id":"{}","name":"{}","installed":{},"accel":"{}","version":{},"role":"{}","install_hint":"{}"}}"#,
                esc(&b.id),
                esc(&b.name),
                b.installed,
                esc(&b.accel.label()),
                b.version.as_deref().map(|v| format!("\"{}\"", esc(v))).unwrap_or_else(|| "null".to_string()),
                esc(&b.role),
                esc(&b.install_hint),
            )
        })
        .collect();
    format!("[{}]", items.join(","))
}

fn models_json() -> String {
    let items: Vec<String> = MODELS
        .iter()
        .map(|m| {
            format!(
                r#"{{"name":"{}","params_b":{},"active_b":{},"q4_gb":{},"cat":"{}","tag":{},"note":"{}"}}"#,
                esc(m.name),
                m.params_b,
                m.active_b,
                m.q4_gb,
                esc(&m.cat.label()),
                m.tag.map(|t| format!("\"{}\"", esc(t))).unwrap_or_else(|| "null".to_string()),
                esc(m.note),
            )
        })
        .collect();
    format!("[{}]", items.join(","))
}

fn advise_json(query: &str) -> String {
    let h = mindmodel_probe::probe();
    let bw = query_param_f64(query, "bandwidth").unwrap_or_else(|| mindmodel_probe::measure_bandwidth(1024, 3));
    let budget = query_param_f64(query, "budget").unwrap_or_else(|| h.budget_gb());
    let ctx = query_param_u32(query, "ctx").unwrap_or(16384);
    let a = Advisor::new(budget, bw, ctx);
    let p = match query_param(query, "purpose").as_deref() {
        Some("coding") => Purpose::Coding,
        Some("reasoning") => Purpose::Reasoning,
        Some("vision") => Purpose::Vision,
        Some("longdoc") => Purpose::LongDoc,
        Some("alwayson") => Purpose::AlwaysOn,
        _ => Purpose::Writing,
    };
    let items: Vec<String> = a
        .top_matches(p, 20)
        .into_iter()
        .map(|adv| {
            format!(
                r#"{{"name":"{}","params_b":{},"q4_gb":{},"need_gb":{},"ratio":{},"level":"{}","est_tok_s":{},"note":"{}"}}"#,
                esc(adv.model.name),
                adv.model.params_b,
                adv.model.q4_gb,
                adv.need_gb,
                adv.ratio,
                esc(&adv.level.label()),
                adv.est_tok_s,
                esc(adv.model.note),
            )
        })
        .collect();
    format!("[{}]", items.join(","))
}

fn task_json(query: &str) -> String {
    let h = mindmodel_probe::probe();
    let bw = query_param_f64(query, "bandwidth").unwrap_or_else(|| mindmodel_probe::measure_bandwidth(1024, 3));
    let budget = query_param_f64(query, "budget").unwrap_or_else(|| h.budget_gb());
    let ctx = query_param_u32(query, "ctx").unwrap_or(16384);
    let a = Advisor::new(budget, bw, ctx);

    let tasks: Vec<WorkTask> = query_param(query, "tasks")
        .map(|s| s.split(',').filter_map(|t| WorkTask::from_key(t.trim())).collect())
        .unwrap_or_else(|| vec![WorkTask::Paper]);
    let blend = TaskBlend::new(tasks.clone());

    let (matches, _rep) = a.task_matches_with_report(&blend, 8);
    let items: Vec<String> = matches
        .iter()
        .map(|adv| {
            let c = capability_of(adv.model);
            let reason = a.task_reason(adv, &blend);
            format!(
                r#"{{"name":"{}","capability_score":{:.4},"zh":{},"writing":{},"code":{},"math":{},"need_gb":{},"ratio":{},"est_tok_s":{},"reason":"{}"}}"#,
                esc(adv.model.name),
                a.capability_score(adv.model, &blend),
                c.zh,
                c.writing,
                c.code,
                c.math,
                adv.need_gb,
                adv.ratio,
                adv.est_tok_s,
                esc(&reason),
            )
        })
        .collect();

    // 附上所选任务与角色的说明，便于前端展示
    let task_labels: Vec<String> = tasks.iter().map(|t| t.label().to_string()).collect();
    format!(
        r#"{{"tasks":[{}],"matches":[{}]}}"#,
        task_labels.iter().map(|l| format!("\"{}\"", esc(l))).collect::<Vec<_>>().join(","),
        items.join(",")
    )
}

fn query_param(query: &str, key: &str) -> Option<String> {
    for pair in query.split('&') {
        let (k, v) = pair.split_once('=')?;
        if k == key {
            return Some(url_decode(v));
        }
    }
    None
}

fn query_param_f64(query: &str, key: &str) -> Option<f64> {
    query_param(query, key).and_then(|s| s.parse().ok())
}

fn query_param_u32(query: &str, key: &str) -> Option<u32> {
    query_param(query, key).and_then(|s| s.parse().ok())
}

fn url_decode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(v as char);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i] as char);
        i += 1;
    }
    out
}
