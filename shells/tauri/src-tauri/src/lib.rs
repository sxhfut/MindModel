//! Tauri 壳的 Rust 侧：把 core/probe/backend 的能力暴露给前端。
//! 前端（ui/）只做展示与交互，所有算法在这里跑。
//! 状态：骨架。编译通过 ≠ 三平台实机验证（见 DESIGN.md 的平台矩阵）。

use mindmodel_backend;
use mindmodel_core::{Advisor, MODELS};
use mindmodel_probe;

#[tauri::command]
fn scan() -> ScanResult {
    let h = mindmodel_probe::probe();
    let bw = mindmodel_probe::measure_bandwidth(1024, 3);
    let budget = h.budget_gb();
    let a = Advisor::new(budget, bw, 16384);
    let fit = MODELS.iter().filter(|m| a.level(m) != mindmodel_core::FitLevel::TooHeavy).count();
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

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![scan, engines])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
