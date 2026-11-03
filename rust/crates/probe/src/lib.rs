//! 硬件探测与带宽实测。零外部依赖，按 target 条件编译。
//!
//! 覆盖状态（诚实标注，编译通过 ≠ 已验证）：
//! - macOS：已验证（sysctl + Metal 建议工作集 + system_profiler）
//! - Linux：写出但未在实机验证（/proc + lspci + nvidia-smi）
//! - Windows：写出但未在实机验证（PowerShell CIM 查询）
//! - 其他（LoongArch 等）：仅 /proc 兜底

use std::process::Command;

#[derive(Debug, Clone, Default)]
pub struct Hardware {
    pub chip: String,
    pub machine_model: String,
    pub os: String,
    pub total_cores: usize,
    pub perf_cores: usize,
    pub eff_cores: usize,
    pub gpu_name: String,
    pub gpu_cores: u32,
    pub ram_gb: f64,
    /// Metal / DXGI 建议工作集；0 表示该平台无法取得
    pub working_set_gb: f64,
    pub working_set_estimated: bool,
    pub disk_free_gb: f64,
    pub disk_total_gb: f64,
    pub unified_memory: bool,
    /// 探测方式说明，用于报告里标注可信度
    pub provenance: String,
}

impl Hardware {
    /// 可用于权重的统一内存预算：取工作集与 80% 物理内存的较小值
    pub fn budget_gb(&self) -> f64 {
        let ws = if self.working_set_gb > 0.0 {
            self.working_set_gb
        } else {
            self.ram_gb * 0.75
        };
        ws.min(self.ram_gb * 0.80)
    }
}

pub fn probe() -> Hardware {
    #[cfg(target_os = "macos")]
    {
        macos::probe()
    }
    #[cfg(target_os = "linux")]
    {
        linux::probe()
    }
    #[cfg(target_os = "windows")]
    {
        windows::probe()
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
    {
        fallback::probe()
    }
}

/// 多轮独立计时采样（GB/s），读+写计双倍流量。
///
/// 为什么必须「每轮单独计时、取最大值」而不是「总时长 ÷ 轮数」：
/// 实测同一台机器上总时长平均会给出 45 / 135 / 263 GB/s 这种乱跳的数，
/// 因为首轮缺页、调度抖动、其他进程抢带宽都会被摊进平均里。
/// 我们关心的是「这台机器最快能把权重喂给 GPU 多快」，所以取峰值轮次，
/// 同时把区间一并交给上层展示（波动大就说明当时机器不空闲，结果不可尽信）。
pub fn bandwidth_samples(size_mb: usize, rounds: usize) -> Vec<f64> {
    let bytes = size_mb * 1024 * 1024;
    if bytes == 0 || rounds == 0 {
        return Vec::new();
    }
    let threads = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4)
        .min(64);
    let src = vec![0x5Au8; bytes];
    let mut dst = vec![0u8; bytes];
    let chunk = (bytes / threads).max(4096);

    // 两次预热：首次建页表、第二次把 cache/dst 页都踩实
    copy_pass(&src, &mut dst, chunk);
    copy_pass(&src, &mut dst, chunk);

    let mut out = Vec::with_capacity(rounds);
    for _ in 0..rounds {
        let start = std::time::Instant::now();
        copy_pass(&src, &mut dst, chunk);
        let secs = start.elapsed().as_secs_f64();
        if secs > 0.0 {
            out.push(bytes as f64 * 2.0 / 1_073_741_824.0 / secs);
        }
    }
    out
}

/// 取峰值轮次作为实测带宽；调用方可通过 `bandwidth_samples` 拿到波动区间。
pub fn measure_bandwidth(size_mb: usize, rounds: usize) -> f64 {
    bandwidth_samples(size_mb, rounds)
        .into_iter()
        .fold(0.0_f64, f64::max)
}

/// 采样 → (峰值, 中位, 最低)，用于界面标注可信度
pub fn summarize(samples: &[f64]) -> (f64, f64, f64) {
    if samples.is_empty() {
        return (0.0, 0.0, 0.0);
    }
    let mut v = samples.to_vec();
    v.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let best = *v.last().unwrap();
    let worst = v[0];
    let med = v[v.len() / 2];
    (best, med, worst)
}

fn copy_pass(src: &[u8], dst: &mut [u8], chunk: usize) {
    std::thread::scope(|s| {
        for (a, b) in src.chunks(chunk).zip(dst.chunks_mut(chunk)) {
            s.spawn(move || b.copy_from_slice(a));
        }
    });
}

fn run(cmd: &str, args: &[&str]) -> String {
    match Command::new(cmd).args(args).output() {
        Ok(o) => String::from_utf8_lossy(&o.stdout).into_owned(),
        Err(_) => String::new(),
    }
}

// ---------------------------------------------------------------- macOS

#[cfg(target_os = "macos")]
mod macos {
    use super::{run, Hardware};
    use std::ffi::CString;
    use std::os::raw::{c_char, c_int, c_void};

    extern "C" {
        fn sysctlbyname(
            name: *const c_char,
            oldp: *mut c_void,
            oldlenp: *mut usize,
            newp: *mut c_void,
            newlen: usize,
        ) -> c_int;
    }

    #[link(name = "objc")]
    extern "C" {
        fn sel_registerName(name: *const c_char) -> *const c_void;
        fn objc_msgSend();
    }

    #[link(name = "Metal", kind = "framework")]
    extern "C" {
        fn MTLCreateSystemDefaultDevice() -> *mut c_void;
    }

    fn sysctl_string(key: &str) -> Option<String> {
        let c = CString::new(key).ok()?;
        let mut size: usize = 0;
        let rc = unsafe {
            sysctlbyname(
                c.as_ptr(),
                std::ptr::null_mut(),
                &mut size,
                std::ptr::null_mut(),
                0,
            )
        };
        if rc != 0 || size == 0 {
            return None;
        }
        let mut buf = vec![0u8; size];
        let rc = unsafe {
            sysctlbyname(
                c.as_ptr(),
                buf.as_mut_ptr() as *mut c_void,
                &mut size,
                std::ptr::null_mut(),
                0,
            )
        };
        if rc != 0 {
            return None;
        }
        Some(
            String::from_utf8_lossy(&buf)
                .trim_end_matches('\0')
                .trim()
                .to_string(),
        )
    }

    fn sysctl_u64(key: &str) -> Option<u64> {
        let c = CString::new(key).ok()?;
        let mut v: u64 = 0;
        let mut size = std::mem::size_of::<u64>();
        let rc = unsafe {
            sysctlbyname(
                c.as_ptr(),
                &mut v as *mut u64 as *mut c_void,
                &mut size,
                std::ptr::null_mut(),
                0,
            )
        };
        if rc != 0 {
            return None;
        }
        Some(v)
    }

    /// Metal 的 recommendedMaxWorkingSetSize：objc_msgSend 取 NSUInteger（arm64 下 u64）
    fn metal_working_set() -> Option<f64> {
        unsafe {
            let dev = MTLCreateSystemDefaultDevice();
            if dev.is_null() {
                return None;
            }
            let sel = sel_registerName(b"recommendedMaxWorkingSetSize\0".as_ptr() as *const c_char);
            if sel.is_null() {
                return None;
            }
            let f: unsafe extern "C" fn(*mut c_void, *const c_void) -> u64 =
                std::mem::transmute(objc_msgSend as *const ());
            let v = f(dev, sel);
            if v == 0 {
                None
            } else {
                Some(v as f64 / 1_073_741_824.0)
            }
        }
    }

    pub fn probe() -> Hardware {
        let mut h = Hardware::default();
        h.provenance = "sysctl + Metal + system_profiler（已验证）".into();
        h.chip = sysctl_string("machdep.cpu.brand_string").unwrap_or_else(|| "未知".into());
        h.machine_model = sysctl_string("hw.model").unwrap_or_else(|| "未知".into());
        let ov = run("sw_vers", &["-productVersion"]).trim().to_string();
        h.os = format!("macOS {ov}");
        h.total_cores = sysctl_u64("hw.ncpu").unwrap_or(0) as usize;
        h.perf_cores = sysctl_u64("hw.perflevel0.physicalcpu").unwrap_or(0) as usize;
        h.eff_cores = sysctl_u64("hw.perflevel1.physicalcpu").unwrap_or(0) as usize;
        if let Some(mem) = sysctl_u64("hw.memsize") {
            h.ram_gb = mem as f64 / 1_073_741_824.0;
        }
        if let Some(ws) = metal_working_set() {
            h.working_set_gb = ws;
        } else {
            h.working_set_gb = h.ram_gb * 0.75;
            h.working_set_estimated = true;
        }
        let sp = run("/usr/sbin/system_profiler", &["SPDisplaysDataType"]);
        for line in sp.lines() {
            let t = line.trim();
            if let Some(rest) = t.strip_prefix("Chipset Model:") {
                h.gpu_name = rest.trim().to_string();
            }
            if let Some(rest) = t.strip_prefix("Total Number of Cores:") {
                h.gpu_cores = rest.trim().parse().unwrap_or(0);
            }
        }
        h.unified_memory = h.chip.contains("Apple");
        let df = run("df", &["-k", "/"]);
        if let Some(line) = df.lines().nth(1) {
            let f: Vec<&str> = line.split_whitespace().collect();
            if f.len() >= 4 {
                let total = f[1].parse::<f64>().unwrap_or(0.0) / 1_048_576.0;
                let free = f[3].parse::<f64>().unwrap_or(0.0) / 1_048_576.0;
                h.disk_total_gb = total;
                h.disk_free_gb = free;
            }
        }
        h
    }
}

// ---------------------------------------------------------------- Linux

#[cfg(target_os = "linux")]
mod linux {
    use super::{run, Hardware};

    fn meminfo(key: &str) -> Option<f64> {
        let s = std::fs::read_to_string("/proc/meminfo").ok()?;
        for line in s.lines() {
            if line.starts_with(key) {
                let num: String = line
                    .chars()
                    .skip(key.len())
                    .take_while(|c| c.is_ascii_digit())
                    .collect();
                return num.parse::<f64>().ok().map(|kb| kb / 1_048_576.0);
            }
        }
        None
    }

    pub fn probe() -> Hardware {
        let mut h = Hardware::default();
        h.provenance = "/proc + lspci + nvidia-smi（未在实机验证）".into();
        let cpuinfo = std::fs::read_to_string("/proc/cpuinfo").unwrap_or_default();
        for line in cpuinfo.lines() {
            if let Some((k, v)) = line.split_once(':') {
                if k.trim() == "model name" {
                    h.chip = v.trim().to_string();
                    break;
                }
            }
        }
        if h.chip.is_empty() {
            h.chip = run("uname", &["-m"]).trim().to_string();
        }
        h.machine_model = run("uname", &["-n"]).trim().to_string();
        h.os = format!(
            "{} {}",
            run("uname", &["-s"]).trim(),
            run("uname", &["-r"]).trim()
        );
        h.total_cores = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(0);
        h.ram_gb = meminfo("MemTotal:").unwrap_or(0.0);
        // 国产平台常见：aarch64 / loongarch64，统一内存形态
        h.unified_memory = matches!(
            std::env::consts::ARCH,
            "aarch64" | "loongarch64" | "riscv64"
        );

        let smi = run("nvidia-smi", &["--query-gpu=name,memory.total", "--format=csv,noheader"]);
        if let Some(first) = smi.lines().next() {
            let parts: Vec<&str> = first.split(',').map(|s| s.trim()).collect();
            if let Some(name) = parts.first() {
                h.gpu_name = name.to_string();
            }
            if let Some(m) = parts.get(1) {
                let mb: f64 = m
                    .trim_end_matches(" MiB")
                    .trim()
                    .parse()
                    .unwrap_or(0.0);
                h.working_set_gb = mb / 1024.0 * 0.95;
            }
        }
        if h.gpu_name.is_empty() {
            let lspci = run("lspci", &[]);
            for line in lspci.lines() {
                if line.contains("VGA") || line.contains("3D controller") {
                    h.gpu_name = line
                        .split(": ")
                        .nth(1)
                        .unwrap_or("未知")
                        .to_string();
                    break;
                }
            }
        }
        if h.working_set_gb == 0.0 {
            h.working_set_gb = h.ram_gb * 0.75;
            h.working_set_estimated = true;
        }
        let df = run("df", &["-k", "/"]);
        if let Some(line) = df.lines().nth(1) {
            let f: Vec<&str> = line.split_whitespace().collect();
            if f.len() >= 4 {
                h.disk_total_gb = f[1].parse::<f64>().unwrap_or(0.0) / 1_048_576.0;
                h.disk_free_gb = f[3].parse::<f64>().unwrap_or(0.0) / 1_048_576.0;
            }
        }
        h
    }
}

// ---------------------------------------------------------------- Windows

#[cfg(target_os = "windows")]
mod windows {
    use super::{run, Hardware};

    fn ps(script: &str) -> String {
        run(
            "powershell",
            &["-NoProfile", "-NonInteractive", "-Command", script],
        )
    }

    pub fn probe() -> Hardware {
        let mut h = Hardware::default();
        h.provenance = "PowerShell CIM（未在实机验证）".into();
        h.chip = ps("(Get-CimInstance Win32_Processor).Name").trim().to_string();
        h.machine_model = ps("(Get-CimInstance Win32_ComputerSystem).Model")
            .trim()
            .to_string();
        h.os = ps("(Get-CimInstance Win32_OperatingSystem).Caption")
            .trim()
            .to_string();
        h.total_cores = ps("(Get-CimInstance Win32_Processor).NumberOfLogicalProcessors")
            .trim()
            .parse()
            .unwrap_or(0);
        let ram = ps("(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory")
            .trim()
            .parse::<f64>()
            .unwrap_or(0.0);
        h.ram_gb = ram / 1_073_741_824.0;
        let gpu = ps("(Get-CimInstance Win32_VideoController | Select-Object -First 1).Name")
            .trim()
            .to_string();
        h.gpu_name = gpu;
        let vram = ps("(Get-CimInstance Win32_VideoController | Select-Object -First 1).AdapterRAM")
            .trim()
            .parse::<f64>()
            .unwrap_or(0.0);
        h.working_set_gb = if vram > 0.0 {
            vram / 1_073_741_824.0 * 0.95
        } else {
            h.ram_gb * 0.75
        };
        h.working_set_estimated = vram <= 0.0;
        h.unified_memory = false;
        let disk = ps("(Get-CimInstance Win32_LogicalDisk -Filter \"DeviceID='C:'\").FreeSpace")
            .trim()
            .parse::<f64>()
            .unwrap_or(0.0);
        let total = ps("(Get-CimInstance Win32_LogicalDisk -Filter \"DeviceID='C:'\").Size")
            .trim()
            .parse::<f64>()
            .unwrap_or(0.0);
        h.disk_free_gb = disk / 1_073_741_824.0;
        h.disk_total_gb = total / 1_073_741_824.0;
        h
    }
}

// ---------------------------------------------------------------- 兜底

#[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
mod fallback {
    use super::{run, Hardware};

    pub fn probe() -> Hardware {
        let mut h = Hardware::default();
        h.provenance = format!("/proc 兜底，架构 {}（未验证）", std::env::consts::ARCH);
        h.chip = run("uname", &["-m"]).trim().to_string();
        h.os = run("uname", &["-a"]).trim().to_string();
        h.total_cores = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(0);
        if let Ok(s) = std::fs::read_to_string("/proc/meminfo") {
            for line in s.lines() {
                if line.starts_with("MemTotal:") {
                    let num: String = line
                        .chars()
                        .skip("MemTotal:".len())
                        .take_while(|c| c.is_ascii_digit())
                        .collect();
                    h.ram_gb = num.parse::<f64>().unwrap_or(0.0) / 1_048_576.0;
                    break;
                }
            }
        }
        h.working_set_gb = h.ram_gb * 0.75;
        h.working_set_estimated = true;
        h.unified_memory = true;
        h
    }
}
