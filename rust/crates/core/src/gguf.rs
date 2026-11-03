//! GGUF 头部解析：只读元数据，不碰权重数据。
//!
//! 三个曾经踩过的坑，在此固定为约束：
//! 1. 数组必须按真实元素个数跳过——分词表常有 12.8 万条字符串，截断即全表错位，
//!    参数量会退化成"按文件体积猜"，把 70B 算成 36B。
//! 2. 全程边界检查，任何越界只置 `bad` 并停止，绝不 panic。
//! 3. `split.*` 键并非所有文件都有（ollama blob 就没有），因此分片必须靠文件名兜底。

use std::fs::File;
use std::io::Read;
use std::path::Path;

#[derive(Debug, Clone)]
pub struct GgufInfo {
    pub file_name: String,
    pub path: String,
    pub arch: String,
    pub model_name: String,
    pub quant: String,
    /// 参数量（十亿）
    pub params_b: f64,
    pub file_gb: f64,
    pub context_length: u64,
    pub block_count: u64,
    pub head_count_kv: u64,
    pub head_count: u64,
    pub embedding_length: u64,
    pub tensor_count: usize,
    /// 每 1K token 的 KV cache，单位 GB（f16）
    pub kv_per_1k_gb: f64,
    pub params_estimated: bool,
    pub truncated: bool,
    pub split_count: u32,
    pub split_no: u32,
    pub has_vision: bool,
    pub is_projector: bool,
    pub has_chat_template: bool,
}

impl Default for GgufInfo {
    fn default() -> Self {
        Self {
            file_name: String::new(),
            path: String::new(),
            arch: String::new(),
            model_name: String::new(),
            quant: String::from("?"),
            params_b: 0.0,
            file_gb: 0.0,
            context_length: 0,
            block_count: 0,
            head_count_kv: 0,
            head_count: 0,
            embedding_length: 0,
            tensor_count: 0,
            kv_per_1k_gb: 0.0,
            params_estimated: false,
            truncated: false,
            split_count: 1,
            split_no: 0,
            has_vision: false,
            is_projector: false,
            has_chat_template: false,
        }
    }
}

const GV: [u32; 12] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
const K_U8: u32 = 0;
const K_I8: u32 = 1;
const K_U16: u32 = 2;
const K_I16: u32 = 3;
const K_U32: u32 = 4;
const K_I32: u32 = 5;
const K_F32: u32 = 6;
const K_BOOL: u32 = 7;
const K_STRING: u32 = 8;
const K_ARRAY: u32 = 9;
const K_U64: u32 = 10;
const K_I64: u32 = 11;
const K_F64: u32 = 12;

#[allow(dead_code)]
fn _keep_gv_used() -> usize {
    GV.len()
}

struct Reader<'a> {
    d: &'a [u8],
    pos: usize,
    bad: bool,
}

impl<'a> Reader<'a> {
    fn new(d: &'a [u8]) -> Self {
        Self { d, pos: 0, bad: false }
    }

    fn need(&mut self, n: usize) -> bool {
        match self.pos.checked_add(n) {
            Some(end) if end <= self.d.len() => true,
            _ => {
                self.bad = true;
                false
            }
        }
    }

    fn u32(&mut self) -> u32 {
        if !self.need(4) {
            return 0;
        }
        let mut b = [0u8; 4];
        b.copy_from_slice(&self.d[self.pos..self.pos + 4]);
        self.pos += 4;
        u32::from_le_bytes(b)
    }

    fn u64(&mut self) -> u64 {
        if !self.need(8) {
            return 0;
        }
        let mut b = [0u8; 8];
        b.copy_from_slice(&self.d[self.pos..self.pos + 8]);
        self.pos += 8;
        u64::from_le_bytes(b)
    }

    fn skip(&mut self, n: usize) {
        match self.pos.checked_add(n) {
            Some(end) if end <= self.d.len() => self.pos = end,
            _ => {
                self.bad = true;
                self.pos = self.pos.min(self.d.len());
            }
        }
    }

    fn string(&mut self) -> String {
        let n = self.u64();
        if self.bad || n > 8_000_000 {
            return String::new();
        }
        let n = n as usize;
        if !self.need(n) {
            return String::new();
        }
        let s = String::from_utf8_lossy(&self.d[self.pos..self.pos + n]).into_owned();
        self.pos += n;
        s
    }

    fn skip_string(&mut self) {
        let n = self.u64();
        if self.bad || n > 200_000_000 {
            return;
        }
        self.skip(n as usize);
    }

    fn width(t: u32) -> Option<usize> {
        match t {
            K_U8 | K_I8 | K_BOOL => Some(1),
            K_U16 | K_I16 => Some(2),
            K_U32 | K_I32 | K_F32 => Some(4),
            K_U64 | K_I64 | K_F64 => Some(8),
            _ => None,
        }
    }

    fn num(&mut self, t: u32) -> f64 {
        match t {
            K_U8 => {
                let v = self.d.get(self.pos).copied().unwrap_or(0);
                self.skip(1);
                v as f64
            }
            K_I8 => {
                let v = self.d.get(self.pos).copied().unwrap_or(0);
                self.skip(1);
                (v as i8) as f64
            }
            K_U16 => {
                if !self.need(2) {
                    return 0.0;
                }
                let mut b = [0u8; 2];
                b.copy_from_slice(&self.d[self.pos..self.pos + 2]);
                self.pos += 2;
                u16::from_le_bytes(b) as f64
            }
            K_I16 => {
                if !self.need(2) {
                    return 0.0;
                }
                let mut b = [0u8; 2];
                b.copy_from_slice(&self.d[self.pos..self.pos + 2]);
                self.pos += 2;
                i16::from_le_bytes(b) as f64
            }
            K_U32 => self.u32() as f64,
            K_I32 => self.u32() as i32 as f64,
            K_F32 => {
                if !self.need(4) {
                    return 0.0;
                }
                let mut b = [0u8; 4];
                b.copy_from_slice(&self.d[self.pos..self.pos + 4]);
                self.pos += 4;
                f32::from_le_bytes(b) as f64
            }
            K_BOOL => {
                let v = self.d.get(self.pos).copied().unwrap_or(0);
                self.skip(1);
                v as f64
            }
            K_U64 => self.u64() as f64,
            K_I64 => self.u64() as i64 as f64,
            K_F64 => {
                if !self.need(8) {
                    return 0.0;
                }
                let mut b = [0u8; 8];
                b.copy_from_slice(&self.d[self.pos..self.pos + 8]);
                self.pos += 8;
                f64::from_le_bytes(b)
            }
            _ => {
                // 未知标量：按数组/字符串规则跳过，宁可保守也不能错位
                self.skip_value(t);
                0.0
            }
        }
    }

    fn skip_value(&mut self, t: u32) {
        match t {
            K_STRING => self.skip_string(),
            K_ARRAY => {
                let et = self.u32();
                let n = self.u64();
                if self.bad || n > 50_000_000 {
                    self.bad = true;
                    return;
                }
                match Reader::width(et) {
                    Some(w) => {
                        let total = (n as usize).saturating_mul(w);
                        self.skip(total); // 定长数组一次跳过
                    }
                    None => {
                        for _ in 0..n {
                            self.skip_value(et); // 字符串数组逐个跳过，不分配内存
                            if self.bad {
                                return;
                            }
                        }
                    }
                }
            }
            _ => match Reader::width(t) {
                Some(w) => self.skip(w),
                None => self.bad = true,
            },
        }
    }
}

/// ggml 文件类型 → 量化名，与 llama.cpp 枚举一致
pub fn quant_name(v: u64) -> String {
    match v {
        0 => "F32".into(),
        1 => "F16".into(),
        2 => "Q4_0".into(),
        3 => "Q4_1".into(),
        7 => "Q8_0".into(),
        8 => "Q5_0".into(),
        9 => "Q5_1".into(),
        10 => "Q2_K".into(),
        11 => "Q3_K_S".into(),
        12 => "Q3_K_M".into(),
        13 => "Q3_K_L".into(),
        14 => "Q4_K_S".into(),
        15 => "Q4_K_M".into(),
        16 => "Q5_K_S".into(),
        17 => "Q5_K_M".into(),
        18 => "Q6_K".into(),
        19 => "IQ2_XXS".into(),
        20 => "IQ2_XS".into(),
        24 => "IQ1_S".into(),
        25 => "IQ4_NL".into(),
        28 => "IQ2_S".into(),
        29 => "IQ2_M".into(),
        30 => "IQ4_XS".into(),
        31 => "IQ1_M".into(),
        32 => "BF16".into(),
        other => format!("type{other}"),
    }
}

/// 量化 → 每参数比特数，仅用于"读不到张量表时反推参数量"
pub fn bits_per_param(quant: &str) -> f64 {
    let q = quant.to_uppercase();
    if q.contains("BF16") || q.contains("F16") {
        16.0
    } else if q.contains("F32") {
        32.0
    } else if q.contains("Q8") {
        8.5
    } else if q.contains("Q6") {
        6.6
    } else if q.contains("Q5") {
        5.6
    } else if q.contains("Q4") {
        4.6
    } else if q.contains("Q3") {
        3.9
    } else if q.contains("Q2") {
        3.0
    } else {
        5.0
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct SplitToken {
    pub prefix: String,
    pub no: u32,
    pub count: u32,
}

/// 解析 "xxx-00002-of-00003.gguf" → prefix "xxx", no 2, count 3
pub fn split_token(file_name: &str) -> Option<SplitToken> {
    let lower: Vec<char> = file_name.to_lowercase().chars().collect();
    let n = lower.len();
    if n < 19 {
        return None;
    }
    for i in 0..n {
        // -DDDDD-of-DDDDD
        if lower[i] != '-' {
            continue;
        }
        if i + 1 + 5 + 4 + 5 > n {
            break;
        }
        let digits_ok = |s: usize, len: usize| lower[s..s + len].iter().all(|c| c.is_ascii_digit());
        if !digits_ok(i + 1, 5) {
            continue;
        }
        let of_seg: String = lower[i + 6..i + 10].iter().collect();
        if of_seg != "-of-" {
            continue;
        }
        if !digits_ok(i + 10, 5) {
            continue;
        }
        let no: String = lower[i + 1..i + 6].iter().collect();
        let cnt: String = lower[i + 10..i + 15].iter().collect();
        let (no, cnt) = match (no.parse::<u32>(), cnt.parse::<u32>()) {
            (Ok(a), Ok(b)) if b > 1 => (a, b),
            _ => continue,
        };
        let prefix: String = file_name.chars().take(i).collect();
        return Some(SplitToken { prefix, no, count: cnt });
    }
    None
}

pub fn parse(path: &Path) -> Option<GgufInfo> {
    let md = std::fs::metadata(path).ok()?;
    let mut f = File::open(path).ok()?;
    let mut head = vec![0u8; 64 * 1024 * 1024];
    let read = f.read(&mut head).ok()?;
    head.truncate(read);
    if head.len() < 24 {
        return None;
    }

    let mut info = GgufInfo::default();
    info.path = path.display().to_string();
    info.file_name = path
        .file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default();
    info.file_gb = md.len() as f64 / 1_073_741_824.0;

    let mut r = Reader::new(&head);
    if r.u32() != 0x4655_4747 {
        return None; // "GGUF"
    }
    let version = r.u32();
    if !(2..=4).contains(&version) {
        return None;
    }
    let tensor_count = r.u64();
    let kv_count = r.u64();
    if r.bad || kv_count == 0 || kv_count > 100_000 || tensor_count > 2_000_000 {
        return None;
    }

    for _ in 0..kv_count {
        let key = r.string();
        let t = r.u32();
        if r.bad {
            info.truncated = true;
            break;
        }
        let watched = key == "general.architecture"
            || key == "general.name"
            || key == "general.file_type"
            || key == "split.count"
            || key == "split.no"
            || key == "clip.has_vision_encoder"
            || key == "tokenizer.chat_template"
            || key.ends_with(".block_count")
            || key.ends_with(".context_length")
            || key.ends_with(".attention.head_count_kv")
            || key.ends_with(".attention.head_count")
            || key.ends_with(".embedding_length");

        if watched {
            if t == K_STRING {
                let s = r.string();
                match key.as_str() {
                    "general.architecture" => info.arch = s,
                    "general.name" => info.model_name = s,
                    "tokenizer.chat_template" => info.has_chat_template = !s.is_empty(),
                    _ => {}
                }
            } else {
                let v = r.num(t);
                if key == "general.file_type" {
                    info.quant = quant_name(v as u64);
                } else if key == "split.count" {
                    info.split_count = (v as u32).max(1);
                } else if key == "split.no" {
                    info.split_no = v as u32;
                } else if key == "clip.has_vision_encoder" {
                    info.has_vision = v > 0.0;
                } else if key.ends_with(".block_count") {
                    info.block_count = v as u64;
                } else if key.ends_with(".context_length") {
                    info.context_length = v as u64;
                } else if key.ends_with(".attention.head_count_kv") {
                    info.head_count_kv = v as u64;
                } else if key.ends_with(".attention.head_count") {
                    info.head_count = v as u64;
                } else if key.ends_with(".embedding_length") {
                    info.embedding_length = v as u64;
                }
            }
        } else {
            r.skip_value(t);
        }
        if r.bad {
            info.truncated = true;
            break;
        }
    }

    // 张量信息表：参数量 = 各张量维度连乘之和
    if !r.bad && tensor_count > 0 && tensor_count < 1_000_000 {
        let mut params: f64 = 0.0;
        let mut counted = 0usize;
        for _ in 0..tensor_count {
            let nm = r.string();
            if r.bad || nm.is_empty() {
                break;
            }
            let n_dims = r.u32();
            if r.bad || n_dims == 0 || n_dims > 8 {
                break;
            }
            let mut prod: u64 = 1;
            for _ in 0..n_dims {
                let dim = r.u64();
                if r.bad {
                    break;
                }
                prod = prod.saturating_mul(dim);
            }
            let _dtype = r.u32();
            let _offset = r.u64();
            if r.bad {
                break;
            }
            params += prod as f64;
            counted += 1;
        }
        info.tensor_count = counted;
        let declared = tensor_count as usize;
        if counted == declared && params > 0.0 {
            info.params_b = params / 1e9;
        } else if counted > 0 && params > 0.0 {
            info.params_b = params / counted as f64 * declared as f64 / 1e9;
            info.params_estimated = true;
        }
    }

    // 量化名兜底：从文件名推断
    if info.quant == "?" {
        let l = info.file_name.to_lowercase();
        for q in [
            "q4_k_m", "q4_k_s", "q5_k_m", "q5_k_s", "q6_k", "q8_0", "q4_0", "q3_k_m", "q2_k",
            "bf16", "f16",
        ] {
            if l.contains(q) {
                info.quant = q.to_uppercase();
                break;
            }
        }
    }

    // 投影器与分片的兜底判定
    let low = info.file_name.to_lowercase();
    if info.arch == "clip" || low.contains("mmproj") {
        info.is_projector = true;
        info.has_vision = true;
    }
    if info.split_count <= 1 {
        if let Some(sp) = split_token(&info.file_name) {
            info.split_no = sp.no;
            info.split_count = sp.count;
        }
    }

    if info.params_b <= 0.0 && info.file_gb > 0.0 {
        info.params_b = info.file_gb * 8.0 / bits_per_param(&info.quant);
        info.params_estimated = true;
    }

    // KV cache：2(K/V) × 层数 × KV头数 × head_dim × 2B(f16)
    if info.block_count > 0
        && info.head_count_kv > 0
        && info.embedding_length > 0
        && info.head_count > 0
    {
        let head_dim = info.embedding_length as f64 / info.head_count.max(1) as f64;
        let per_token =
            2.0 * info.block_count as f64 * info.head_count_kv as f64 * head_dim * 2.0;
        info.kv_per_1k_gb = per_token * 1024.0 / 1_073_741_824.0;
    } else if info.file_gb > 0.0 {
        info.kv_per_1k_gb = info.file_gb * 0.012;
    }

    Some(info)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn fixture(name: &str) -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures")
            .join(name)
    }

    #[test]
    fn split_token_parses_shard_names() {
        let t = split_token("Qwen3-VL-30B-Q4_K_M-00002-of-00003.gguf").unwrap();
        assert_eq!(t.prefix, "Qwen3-VL-30B-Q4_K_M");
        assert_eq!(t.no, 2);
        assert_eq!(t.count, 3);
        assert!(split_token("Qwen3-30B-Q4_K_M.gguf").is_none());
        assert!(split_token("mmproj-model-f16.gguf").is_none());
    }

    #[test]
    fn parses_shard_and_projector_fixtures() {
        let shard = parse(&fixture("Qwen3-VL-30B-Q4_K_M-00001-of-00003.gguf")).unwrap();
        assert_eq!(shard.arch, "qwen2vl");
        assert_eq!(shard.quant, "Q4_K_M");
        assert_eq!(shard.split_no, 1);
        assert_eq!(shard.split_count, 3);
        assert_eq!(shard.context_length, 262144);
        assert_eq!(shard.block_count, 48);
        assert_eq!(shard.tensor_count, 2);
        assert!((shard.params_b - 0.8).abs() < 0.05, "params={}", shard.params_b);
        assert!(!shard.is_projector);
        assert!((shard.kv_per_1k_gb - 0.188).abs() < 0.01, "kv={}", shard.kv_per_1k_gb);

        let pj = parse(&fixture("mmproj-Qwen3-VL-30B-f16.gguf")).unwrap();
        assert!(pj.is_projector);
        assert!(pj.has_vision);
        assert_eq!(pj.arch, "clip");
    }

    #[test]
    fn split_falls_back_to_filename_without_kv_keys() {
        let i = parse(&fixture("Big-70B-Q4_K_M-00002-of-00004.gguf")).unwrap();
        assert_eq!(i.split_no, 2, "无 split.* 键时必须靠文件名兜底");
        assert_eq!(i.split_count, 4);
    }
}
