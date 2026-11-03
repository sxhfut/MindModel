//! Tauri 壳的 Rust 侧：把 core/probe/backend 的能力暴露给前端。
//! 前端（ui/）只做展示与交互，所有算法在这里跑。
//! 状态：代码完整，三平台实机验证靠 CI 在对应 runner 上编译产物完成。

use mindmodel_backend;
use mindmodel_core::advisor::{Advisor, FitLevel, Purpose};
use mindmodel_core::{self, MODELS};

#[tauri::command]
fn scan() -> ScanResult {
    let h = mindmodel_probe::probe();
    let bw = mindmodel_probe::measure_bandwidth(1024, 3);
    let budget = h.budget_gb();
    let a = Advisor::new(budget, bw, 16384);
    let fit = MODELS
        .iter()
        .filter(|m| a.level(m) != FitLevel::TooHeavy)
        .count();
    ScanResult {
        chip: h.chip,
        machine_model: h.machine_model,
        os: h.os,
        total_cores: h.total_cores,
        perf_cores: h.perf_cores,
        eff_cores: h.eff_cores,
        gpu_name: h.gpu_name,
        gpu_cores: h.gpu_cores,
        ram_gb: h.ram_gb,
        working_set_gb: h.working_set_gb,
        unified_memory: h.unified_memory,
        disk_free_gb: h.disk_free_gb,
        disk_total_gb: h.disk_total_gb,
        budget_gb: budget,
        bandwidth: bw,
        fit_count: fit,
        total_models: MODELS.len(),
        provenance: h.provenance,
    }
}

#[tauri::command]
fn engines() -> Vec<EngineInfo> {
    mindmodel_backend::detect_all()
        .into_iter()
        .map(|b| EngineInfo {
            id: b.id,
            name: b.name,
            installed: b.installed,
            accel: b.accel.label().to_string(),
            version: b.version,
            role: b.role,
            install_hint: b.install_hint,
        })
        .collect()
}

/// 按用途给推荐。前端传 bandwidth/budget 覆盖实测值，便于离线复算。
#[tauri::command]
fn advise(purpose: String, bandwidth: Option<f64>, budget: Option<f64>, ctx: Option<u32>) -> Vec<AdviceInfo> {
    let h = mindmodel_probe::probe();
    let bw = bandwidth.unwrap_or_else(|| mindmodel_probe::measure_bandwidth(1024, 3));
    let budget = budget.unwrap_or_else(|| h.budget_gb());
    let ctx = ctx.unwrap_or(16384);
    let a = Advisor::new(budget, bw, ctx);
    let p = match purpose.as_str() {
        "coding" => Purpose::Coding,
        "reasoning" => Purpose::Reasoning,
        "vision" => Purpose::Vision,
        "longdoc" => Purpose::LongDoc,
        "alwayson" => Purpose::AlwaysOn,
        _ => Purpose::Writing,
    };
    a.top_matches(p, 20)
        .into_iter()
        .map(|adv| AdviceInfo {
            name: adv.model.name.to_string(),
            params_b: adv.model.params_b,
            q4_gb: adv.model.q4_gb,
            need_gb: adv.need_gb,
            ratio: adv.ratio,
            level: adv.level.label().to_string(),
            est_tok_s: adv.est_tok_s,
            note: adv.model.note.to_string(),
        })
        .collect()
}

/// 模型清单（按分类给前端）。
#[tauri::command]
fn models() -> Vec<ModelInfo> {
    MODELS
        .iter()
        .map(|m| ModelInfo {
            name: m.name.to_string(),
            params_b: m.params_b,
            q4_gb: m.q4_gb,
            cat: m.cat.label().to_string(),
            note: m.note.to_string(),
        })
        .collect()
}

#[derive(serde::Serialize)]
struct ScanResult {
    chip: String,
    machine_model: String,
    os: String,
    total_cores: usize,
    perf_cores: usize,
    eff_cores: usize,
    gpu_name: String,
    gpu_cores: u32,
    ram_gb: f64,
    working_set_gb: f64,
    unified_memory: bool,
    disk_free_gb: f64,
    disk_total_gb: f64,
    budget_gb: f64,
    bandwidth: f64,
    fit_count: usize,
    total_models: usize,
    provenance: String,
}

#[derive(serde::Serialize)]
struct EngineInfo {
    id: String,
    name: String,
    installed: bool,
    accel: String,
    version: Option<String>,
    role: String,
    install_hint: String,
}

#[derive(serde::Serialize)]
struct AdviceInfo {
    name: String,
    params_b: f64,
    q4_gb: f64,
    need_gb: f64,
    ratio: f64,
    level: String,
    est_tok_s: f64,
    note: String,
}

#[derive(serde::Serialize)]
struct ModelInfo {
    name: String,
    params_b: f64,
    q4_gb: f64,
    cat: String,
    note: String,
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![scan, engines, advise, models])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
