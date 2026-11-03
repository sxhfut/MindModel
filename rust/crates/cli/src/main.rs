use std::path::PathBuf;

use mindmodel_core::advisor::{Advisor, FitLevel, Purpose, CTX_OPTIONS};
use mindmodel_core::task::{TaskBlend, WorkTask};
use mindmodel_core::capability::capability_of;
use mindmodel_core::{gguf, MODELS};
use mindmodel_probe::{bandwidth_samples, measure_bandwidth, probe, summarize};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let cmd = args.first().map(|s| s.as_str()).unwrap_or("scan");
    let rest = if args.len() > 1 { &args[1..] } else { &[][..] };

    match cmd {
        "scan" => scan(),
        "advise" => advise(rest),
        "parse" => parse_files(rest),
        "task" => task_cmd(rest),
        "list" => list(),
        "engines" => engines(),
        "help" | "-h" | "--help" => help(),
        other => {
            eprintln!("未知命令：{other}\n");
            help();
            std::process::exit(2);
        }
    }
}

fn help() {
    println!(
        "mindmodel —— 本机能跑什么模型、跑多快

用法：
  mindmodel scan                          硬件体检 + 带宽实测 + 预算
  mindmodel advise [选项]                 按用途给出推荐与理由
      --ctx <tokens>      上下文，默认 16384（可选 {:?}）
      --purpose <用途>    writing|coding|reasoning|vision|longdoc|alwayson
      --bandwidth <GB/s>  覆盖实测带宽（离线复算用）
      --budget <GB>       覆盖预算（离线复算用）
  mindmodel task [选项]                   按角色/任务（可多选）给结论
      --tasks paper,lit,code,debug,data,review,teach,trans,affect,daily,vision,summary
      --ctx <tokens>      上下文，默认 16384
      --bandwidth <GB/s>  覆盖实测带宽（离线复算用）
      --budget <GB>       覆盖预算（离线复算用）
  mindmodel parse <文件...>               解析 GGUF 头部（含分片/投影器识别）
  mindmodel list                          列出内置模型清单
  mindmodel engines                       检测本机推理后端",
        CTX_OPTIONS
    );
}

fn scan() {
    let h = probe();
    let samples = bandwidth_samples(1024, 3);
    let (bw, med, low) = summarize(&samples);
    println!("芯片      : {}", h.chip);
    println!("机型      : {}  {}", h.machine_model, h.os);
    println!(
        "CPU       : {} 核（性能 {} / 能效 {}）",
        h.total_cores, h.perf_cores, h.eff_cores
    );
    println!("GPU       : {} · {} 核", h.gpu_name, h.gpu_cores);
    println!("统一内存  : {:.1} GB（unified={}）", h.ram_gb, h.unified_memory);
    println!(
        "工作集    : {:.1} GB{}",
        h.working_set_gb,
        if h.working_set_estimated { "（估算，非 API 取值）" } else { "" }
    );
    println!("预算      : {:.1} GB", h.budget_gb());
    println!(
        "带宽实测  : {:.0} GB/s（峰值；中位 {:.0} · 最低 {:.0}，波动大说明机器当时不空闲）",
        bw, med, low
    );
    println!(
        "磁盘      : 可用 {:.0} GB / 共 {:.0} GB",
        h.disk_free_gb, h.disk_total_gb
    );
    println!("探测方式  : {}", h.provenance);

    let a = Advisor::new(h.budget_gb(), bw, 16384);
    println!(
        "\n可承载 {}/{} 个内置候选；建议档位 {}",
        a.fit_count(),
        MODELS.len(),
        a.sweet_spot()
    );
}

fn advise(args: &[String]) {
    let h = probe();
    let bw_measured = measure_bandwidth(1024, 3);

    let mut ctx: u32 = 16384;
    let mut purpose: Option<Purpose> = None;
    let mut bandwidth = bw_measured;
    let mut budget = h.budget_gb();

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--ctx" => {
                if let Some(v) = args.get(i + 1).and_then(|s| s.parse::<u32>().ok()) {
                    ctx = v;
                }
                i += 2;
            }
            "--purpose" => {
                purpose = args.get(i + 1).and_then(|s| match s.as_str() {
                    "writing" => Some(Purpose::Writing),
                    "coding" => Some(Purpose::Coding),
                    "reasoning" => Some(Purpose::Reasoning),
                    "vision" => Some(Purpose::Vision),
                    "longdoc" => Some(Purpose::LongDoc),
                    "alwayson" => Some(Purpose::AlwaysOn),
                    _ => None,
                });
                i += 2;
            }
            "--bandwidth" => {
                if let Some(v) = args.get(i + 1).and_then(|s| s.parse::<f64>().ok()) {
                    bandwidth = v;
                }
                i += 2;
            }
            "--budget" => {
                if let Some(v) = args.get(i + 1).and_then(|s| s.parse::<f64>().ok()) {
                    budget = v;
                }
                i += 2;
            }
            _ => i += 1,
        }
    }

    let a = Advisor::new(budget, bandwidth, ctx);
    println!(
        "预算 {:.1} GB · 带宽 {:.0} GB/s · 上下文 {}K\n",
        budget,
        bandwidth,
        ctx / 1024
    );

    match purpose {
        Some(p) => {
            if let Some((adv, reason)) = a.match_purpose(p) {
                println!("{} → {} [{}]", p.label(), adv.model.name, adv.level.label());
                println!("  {reason}");
                println!("  备注：{}", adv.model.note);
            } else {
                println!("{} → 预算内无可用模型", p.label());
            }
        }
        None => {
            for p in Purpose::all() {
                match a.match_purpose(p) {
                    Some((adv, reason)) => println!(
                        "{:<10} → {:<30} [{}] {}",
                        p.label(),
                        adv.model.name,
                        adv.level.label(),
                        reason
                    ),
                    None => println!("{:<10} → 无可用模型", p.label()),
                }
            }
            println!("\n综合排序前 12：");
            println!(
                "  {:<30} {:>8} {:>8} {:>7} {:>6}  {}",
                "模型", "体积", "需求", "占比", "tok/s", "判定"
            );
            for ad in a.ranked(None).into_iter().take(12) {
                println!(
                    "  {:<30} {:>7.1}G {:>7.1}G {:>6.0}% {:>6.0}  {}",
                    ad.model.name,
                    ad.model.q4_gb,
                    ad.need_gb,
                    ad.ratio * 100.0,
                    ad.est_tok_s,
                    level_zh(ad.level)
                );
            }
        }
    }
}

fn level_zh(l: FitLevel) -> &'static str {
    l.label()
}

fn parse_files(files: &[String]) {
    if files.is_empty() {
        eprintln!("请给出至少一个 .gguf 路径");
        std::process::exit(2);
    }
    for f in files {
        let p = PathBuf::from(f);
        match gguf::parse(&p) {
            Some(i) => {
                println!("{}", i.file_name);
                println!(
                    "  架构 {} · 量化 {} · 参数 {:.1}B{} · 体积 {:.1} GB",
                    i.arch,
                    i.quant,
                    i.params_b,
                    if i.params_estimated { "（估）" } else { "" },
                    i.file_gb
                );
                println!(
                    "  上下文 {} · 层数 {} · KV 头 {} · 每 1K KV {:.3} GB · 张量 {}",
                    i.context_length, i.block_count, i.head_count_kv, i.kv_per_1k_gb, i.tensor_count
                );
                println!(
                    "  分片 {}/{} · 投影器 {} · 视觉 {} · 模板 {}",
                    i.split_no,
                    i.split_count,
                    if i.is_projector { "是" } else { "否" },
                    if i.has_vision { "是" } else { "否" },
                    if i.has_chat_template { "内置" } else { "未内置" }
                );
            }
            None => println!("{f}\n  解析失败（非 GGUF、版本不支持或文件损坏）"),
        }
    }
}

fn list() {
    println!("{:<32} {:>7} {:>7} {:<10} {}", "名称", "参数", "Q4体积", "分类", "备注");
    for m in MODELS {
        println!(
            "{:<32} {:>6.1}B {:>6.1}G {:<10} {}",
            m.name,
            m.params_b,
            m.q4_gb,
            m.cat.label(),
            m.note
        );
    }
}

fn engines() {
    println!("{:<10} {:<8} {:<12} {:<10} {}", "后端", "状态", "加速", "版本", "说明");
    for b in mindmodel_backend::detect_all() {
        println!(
            "{:<10} {:<8} {:<12} {:<10} {}",
            b.id,
            if b.installed { "已安装" } else { "未安装" },
            b.accel.label(),
            b.version.as_deref().unwrap_or("—"),
            b.role
        );
    }
}


fn parse_task(name: &str) -> Option<WorkTask> {
    WorkTask::from_key(name)
}

fn task_cmd(args: &[String]) {
    let h = probe();
    let mut ctx: u32 = 16384;
    let mut tasks: Vec<WorkTask> = vec![WorkTask::Paper];
    let mut bandwidth = measure_bandwidth(1024, 3);
    let mut budget = h.budget_gb();

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--ctx" => {
                if let Some(v) = args.get(i + 1).and_then(|x| x.parse::<u32>().ok()) {
                    ctx = v;
                }
                i += 2;
            }
            "--tasks" => {
                if let Some(v) = args.get(i + 1) {
                    let parsed: Vec<WorkTask> = v.split(',').filter_map(parse_task).collect();
                    if !parsed.is_empty() {
                        tasks = parsed;
                    }
                }
                i += 2;
            }
            "--bandwidth" => {
                if let Some(v) = args.get(i + 1).and_then(|x| x.parse::<f64>().ok()) {
                    bandwidth = v;
                }
                i += 2;
            }
            "--budget" => {
                if let Some(v) = args.get(i + 1).and_then(|x| x.parse::<f64>().ok()) {
                    budget = v;
                }
                i += 2;
            }
            _ => i += 1,
        }
    }

    let a = Advisor::new(budget, bandwidth, ctx);
    let blend = TaskBlend::new(tasks.clone());
    println!("任务：{}", blend.label());
    let dims = blend.top_dimensions(3);
    println!(
        "权重前 3：{}",
        dims.iter()
            .map(|(k, v)| format!("{k} {v:.2}"))
            .collect::<Vec<_>>()
            .join(" · ")
    );
    let mut gates = format!(
        "上下文 ≥ {}K · 速度 ≥ {:.0} tok/s · {}",
        blend.min_context() / 1024,
        blend.min_tok_s(),
        if blend.chinese_heavy() { "中文 ≥ 4.0" } else { "不限中文" }
    );
    if blend.categories().contains(&mindmodel_core::advisor::Category::Vision) {
        gates.push_str(" · 须支持看图");
    }
    println!("门槛：{gates}");
    println!(
        "基准：预算 {:.1} GB · 带宽 {:.0} GB/s（按 {}K 估 KV 开销）",
        budget,
        bandwidth,
        ctx / 1024
    );

    let (got, rep) = a.task_matches_with_report(&blend, 4);
    println!("{}", rep.accounting());
    for w in rep.warnings() {
        println!("⚠ {w}");
    }

    if got.is_empty() {
        println!("\n无合适模型：可放宽上下文，或选量化更小的版本。");
        return;
    }
    println!();
    for (idx, adv) in got.iter().enumerate() {
        let c = capability_of(adv.model);
        println!(
            "{} {:<30} 能力{:.2}  中文{:.1} 写作{:.1} 代码{:.1} 数理{:.1}  需{:.0}G {:>4.0} tok/s [{}]",
            if idx == 0 { "★" } else { "·" },
            adv.model.name,
            a.capability_score(adv.model, &blend),
            c.zh,
            c.writing,
            c.code,
            c.math,
            adv.need_gb,
            adv.est_tok_s,
            adv.level.label()
        );
    }
    println!("\n理由：{}", a.task_reason(&got[0], &blend));
}
