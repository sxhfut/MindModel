//! 推理后端抽象。
//!
//! 与 `probe`（硬件探测）不同，这一层管的是"用什么引擎跑模型"：
//! 已有 Ollama 就复用，否则按平台推荐 llama.cpp / MLX / 自定义命令。
//! 这是跨平台壳（Tauri）要接的第一层，也是与"按显存推荐"工具拉开差距的边界——
//! 我们不自己写推理引擎，只做探测、安装、启动与带宽实测的编排。
//!
//! 覆盖状态（诚实标注，编译通过 ≠ 已验证）：
//! - Ollama：已验证（macOS 实跑，`/api/chat` 与 `ollama` CLI 都通）
//! - llama.cpp：写出但未实机验证（`llama-server`/`llama-cli` 探测）
//! - MLX：写出但未实机验证（Apple 专有）
//! - 自定义命令：通用兜底

use std::path::{Path, PathBuf};
use std::process::Command;

/// 加速方式。用于报告里讲清楚"这个引擎在这台机器上怎么跑"。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Accel {
    Metal,
    Cuda,
    Rocm,
    Vulkan,
    Cpu,
}

impl Accel {
    pub fn label(&self) -> &'static str {
        match self {
            Accel::Metal => "Metal",
            Accel::Cuda => "CUDA",
            Accel::Rocm => "ROCm",
            Accel::Vulkan => "Vulkan",
            Accel::Cpu => "CPU",
        }
    }
}

/// 一个推理后端。探测阶段只关心"装没装、在哪、怎么加速"。
#[derive(Debug, Clone)]
pub struct Backend {
    pub id: String,
    pub name: String,
    pub installed: bool,
    pub path: Option<PathBuf>,
    pub version: Option<String>,
    pub accel: Accel,
    pub install_hint: String,
    pub role: String,
}

/// 后端探测的入口。按平台返回可用后端清单，优先级高的排前面。
pub fn detect_all() -> Vec<Backend> {
    let mut list = Vec::new();

    // Ollama 优先：已有就直接复用，不重复造下载器
    if let Some(p) = find_in_path("ollama") {
        list.push(Backend {
            id: "ollama".into(),
            name: "Ollama".into(),
            installed: true,
            path: Some(p),
            version: version_of("ollama"),
            accel: ollama_accel(),
            install_hint: "https://ollama.com/download".into(),
            role: "MLX/GGUF 双引擎，命令行 + OpenAI 兼容 API".into(),
        });
    } else {
        list.push(Backend {
            id: "ollama".into(),
            name: "Ollama".into(),
            installed: false,
            path: None,
            version: None,
            accel: ollama_accel(),
            install_hint: "https://ollama.com/download".into(),
            role: "MLX/GGUF 双引擎".into(),
        });
    }

    // llama.cpp：GGUF 原生
    if let Some(p) = find_in_path("llama-server").or_else(|| find_in_path("llama-cli")) {
        list.push(Backend {
            id: "llama.cpp".into(),
            name: "llama.cpp".into(),
            installed: true,
            path: Some(p),
            version: version_of("llama-server"),
            accel: Accel::Cpu,
            install_hint: "https://github.com/ggml-org/llama.cpp".into(),
            role: "GGUF 原生引擎".into(),
        });
    } else {
        list.push(Backend {
            id: "llama.cpp".into(),
            name: "llama.cpp".into(),
            installed: false,
            path: None,
            version: None,
            accel: Accel::Cpu,
            install_hint: "https://github.com/ggml-org/llama.cpp".into(),
            role: "GGUF 原生引擎".into(),
        });
    }

    // MLX：仅 Apple
    #[cfg(target_os = "macos")]
    {
        let mlx_path = PathBuf::from("/Applications/oMLX.app");
        let installed = mlx_path.exists();
        list.push(Backend {
            id: "mlx".into(),
            name: "Apple MLX".into(),
            installed,
            path: installed.then_some(mlx_path),
            version: None,
            accel: Accel::Metal,
            install_hint: "https://github.com/ml-explore/mlx".into(),
            role: "Apple 官方张量框架，M 系列最快路径".into(),
        });
    }

    list
}

/// 探测阶段：在 PATH 里找可执行文件
fn find_in_path(bin: &str) -> Option<PathBuf> {
    let path_var = std::env::var("PATH").ok()?;
    for dir in path_var.split(':') {
        if dir.is_empty() {
            continue;
        }
        let cand = Path::new(dir).join(bin);
        if cand.is_file() {
            return Some(cand);
        }
    }
    None
}

fn version_of(bin: &str) -> Option<String> {
    let out = Command::new(bin).arg("--version").output().ok()?;
    let s = String::from_utf8_lossy(&out.stdout);
    Some(s.lines().next().unwrap_or("").trim().to_string())
}

fn ollama_accel() -> Accel {
    #[cfg(target_os = "macos")]
    {
        Accel::Metal
    }
    #[cfg(target_os = "windows")]
    {
        Accel::Cuda
    }
    #[cfg(target_os = "linux")]
    {
        Accel::Cuda
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
    {
        Accel::Cpu
    }
}

/// 启动一个推理会话。这里只定义接口，具体实现随平台展开。
/// 返回的 Session 是"能往引擎发请求"的句柄。
pub trait Session {
    fn model(&self) -> &str;
    fn backend(&self) -> &str;
    fn stop(&mut self);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detect_all_returns_ollama_first_when_present() {
        let list = detect_all();
        // 无论装没装，Ollama 都在列表里
        assert!(list.iter().any(|b| b.id == "ollama"));
        // Ollama 排最前（优先级最高）
        assert_eq!(list[0].id, "ollama");
    }

    #[test]
    fn accel_labels_are_stable() {
        assert_eq!(Accel::Metal.label(), "Metal");
        assert_eq!(Accel::Cuda.label(), "CUDA");
        assert_eq!(Accel::Cpu.label(), "CPU");
    }
}
