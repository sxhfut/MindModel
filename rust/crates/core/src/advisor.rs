//! 适配判定与速度推算。全部为纯函数，便于在任意平台复算与单元测试。
//!
//! 与 Swift 版 `Sources/Advisor.swift` 保持同一套公式，验收标准是两端输出一致。

use std::collections::HashMap;

use crate::catalog::MODELS;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Category {
    Chat,
    Code,
    Reason,
    Vision,
    Agent,
    Light,
    Image,
    Speech,
    Embed,
    Rerank,
}

impl Category {
    pub fn label(&self) -> &'static str {
        match self {
            Category::Chat => "通用对话",
            Category::Code => "代码",
            Category::Reason => "推理",
            Category::Vision => "多模态",
            Category::Agent => "Agent",
            Category::Light => "轻量常驻",
            Category::Image => "图像生成",
            Category::Speech => "语音",
            Category::Embed => "向量/嵌入",
            Category::Rerank => "重排",
        }
    }

    /// 能不能当对话模型用。生成图、语音、向量、重排都是另一类模型，
    /// 混进对话推荐里会把它们排到"首选"——这是排序错误，不只是显示问题。
    pub fn chattable(&self) -> bool {
        !matches!(self, Category::Image | Category::Speech | Category::Embed | Category::Rerank)
    }
}

#[derive(Debug, Clone)]
pub struct Model {
    pub name: &'static str,
    /// 总参数（十亿）
    pub params_b: f64,
    /// MoE 激活参数；dense 时等于 params_b
    pub active_b: f64,
    /// Q4_K_M 权重体积（GB）
    pub q4_gb: f64,
    pub cat: Category,
    /// 可信的 ollama tag；None 表示需走 HF 搜索
    pub tag: Option<&'static str>,
    /// 每 1K token 的 KV cache（GB, f16）
    pub kv_1k: f64,
    pub note: &'static str,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FitLevel {
    Plenty,
    Smooth,
    Ok,
    Tight,
    TooHeavy,
}

impl FitLevel {
    pub fn label(&self) -> &'static str {
        match self {
            FitLevel::Plenty => "余量充足",
            FitLevel::Smooth => "流畅",
            FitLevel::Ok => "可运行",
            FitLevel::Tight => "偏紧",
            FitLevel::TooHeavy => "超出预算",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Advice<'a> {
    pub model: &'a Model,
    pub need_gb: f64,
    pub ratio: f64,
    pub level: FitLevel,
    pub est_tok_s: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Purpose {
    Writing,
    Coding,
    Reasoning,
    Vision,
    LongDoc,
    AlwaysOn,
}

impl Purpose {
    pub fn label(&self) -> &'static str {
        match self {
            Purpose::Writing => "中文写作",
            Purpose::Coding => "写代码",
            Purpose::Reasoning => "深度推理",
            Purpose::Vision => "看图",
            Purpose::LongDoc => "长文档 128K",
            Purpose::AlwaysOn => "后台常驻",
        }
    }

    pub fn all() -> [Purpose; 6] {
        [
            Purpose::Writing,
            Purpose::Coding,
            Purpose::Reasoning,
            Purpose::Vision,
            Purpose::LongDoc,
            Purpose::AlwaysOn,
        ]
    }

    pub fn categories(&self) -> &'static [Category] {
        match self {
            Purpose::Writing => &[Category::Chat],
            Purpose::Coding => &[Category::Code, Category::Agent],
            Purpose::Reasoning => &[Category::Reason, Category::Chat],
            Purpose::Vision => &[Category::Vision],
            Purpose::LongDoc => &[Category::Chat, Category::Code, Category::Reason],
            Purpose::AlwaysOn => &[Category::Light, Category::Chat],
        }
    }

    /// 交互可用性的速度下限（tok/s）。低于此值只算"装得下"，不算"能用"。
    pub fn min_tok_s(&self) -> f64 {
        match self {
            Purpose::Writing => 12.0,
            Purpose::Coding => 15.0,
            Purpose::Reasoning => 6.0,
            Purpose::Vision => 12.0,
            Purpose::LongDoc => 8.0,
            Purpose::AlwaysOn => 30.0,
        }
    }

    fn ref_tok_s(&self) -> f64 {
        match self {
            Purpose::Writing => 30.0,
            Purpose::Coding => 45.0,
            Purpose::Reasoning => 15.0,
            Purpose::Vision => 25.0,
            Purpose::LongDoc => 20.0,
            Purpose::AlwaysOn => 60.0,
        }
    }
}

pub const CTX_OPTIONS: [u32; 6] = [4096, 8192, 16384, 32768, 65536, 131072];

#[derive(Debug, Clone)]
pub struct Advisor {
    /// 可用于权重的统一内存预算（GB）
    pub budget_gb: f64,
    /// 实测带宽（GB/s）；<=1 视为未测，退回 400
    pub bandwidth: f64,
    pub context: u32,
    pub benchmarks: HashMap<String, f64>,
}

impl Advisor {
    pub fn new(budget_gb: f64, bandwidth: f64, context: u32) -> Self {
        Self {
            budget_gb,
            bandwidth,
            context,
            benchmarks: HashMap::new(),
        }
    }

    /// 每生成 1 token 需读出的近似字节量（GB）。
    /// MoE 只读激活专家，故按 active/params 折算。
    /// 不可对激活占比设人为下限——那会把 30B-A3B 当成 6B，系统性高估大 dense 模型。
    pub fn bytes_per_token(&self, m: &Model) -> f64 {
        let share = m.active_b / m.params_b.max(1.0);
        m.q4_gb * share.clamp(0.02, 1.0) + 0.25
    }

    /// 权重 + KV + 运行时(1.6 GB)
    pub fn need_at(&self, m: &Model, ctx: u32) -> f64 {
        m.q4_gb + m.kv_1k * (ctx as f64 / 1024.0) + 1.6
    }

    pub fn need(&self, m: &Model) -> f64 {
        self.need_at(m, self.context)
    }

    pub fn ratio(&self, m: &Model) -> f64 {
        self.need(m) / self.budget_gb.max(1.0)
    }

    pub fn level(&self, m: &Model) -> FitLevel {
        let r = self.ratio(m);
        if r <= 0.40 {
            FitLevel::Plenty
        } else if r <= 0.72 {
            FitLevel::Smooth
        } else if r <= 0.92 {
            FitLevel::Ok
        } else if r <= 1.15 {
            FitLevel::Tight
        } else {
            FitLevel::TooHeavy
        }
    }

    /// tok/s ≈ 带宽 × 0.45 ÷ 每 token 字节数。0.45 为保守效率系数，实测值优先覆盖。
    pub fn est_tok_s(&self, m: &Model) -> f64 {
        if let Some(v) = self.benchmarks.get(m.name) {
            return *v;
        }
        let bw = if self.bandwidth > 1.0 { self.bandwidth } else { 400.0 };
        (bw * 0.45 / self.bytes_per_token(m).max(0.3)).clamp(0.4, 260.0)
    }

    /// 仍满足"可运行"（占比 ≤92%）的最大上下文
    pub fn max_context(&self, m: &Model) -> u32 {
        let mut opts = CTX_OPTIONS.to_vec();
        opts.sort_unstable_by(|a, b| b.cmp(a));
        for c in opts {
            if self.need_at(m, c) / self.budget_gb.max(1.0) <= 0.92 {
                return c;
            }
        }
        0
    }

    /// 用途打分：规模按幂次折算，速度不足按幂次衰减
    pub fn score(&self, m: &Model, p: Purpose) -> f64 {
        let tps = self.est_tok_s(m);
        if p == Purpose::AlwaysOn {
            return tps * 2.0 + m.params_b * 0.4;
        }
        let size_term = m.params_b.powf(0.8);
        let speed_term = (tps / p.ref_tok_s()).min(1.0).powf(0.8);
        size_term * speed_term
    }

    pub fn advice<'a>(&self, m: &'a Model) -> Advice<'a> {
        Advice {
            model: m,
            need_gb: self.need(m),
            ratio: self.ratio(m),
            level: self.level(m),
            est_tok_s: self.est_tok_s(m),
        }
    }

    /// 综合排序：规模为主，适配度加权，MoE 有速度加成
    pub fn ranked(&self, cat: Option<Category>) -> Vec<Advice<'_>> {
        let mut scored: Vec<(&Model, f64)> = MODELS
            .iter()
            .filter(|m| cat.map_or(true, |c| m.cat == c))
            .map(|m| {
                let f = match self.level(m) {
                    FitLevel::Plenty => 0.95,
                    FitLevel::Smooth => 1.0,
                    FitLevel::Ok => 0.88,
                    FitLevel::Tight => 0.42,
                    FitLevel::TooHeavy => 0.04,
                };
                let moe = if m.active_b < m.params_b { 1.12 } else { 1.0 };
                (m, m.params_b * f * moe)
            })
            .collect();
        scored.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
        scored.into_iter().map(|(m, _)| self.advice(m)).collect()
    }

    pub fn top_matches(&self, p: Purpose, limit: usize) -> Vec<Advice<'_>> {
        let mut pool: Vec<&Model> = MODELS
            .iter()
            .filter(|m| p.categories().contains(&m.cat))
            .filter(|m| !(p == Purpose::AlwaysOn && m.params_b > 14.0))
            .filter(|m| self.level(m) != FitLevel::TooHeavy)
            .filter(|m| !(p == Purpose::LongDoc && self.max_context(m) < 131_072))
            .collect();

        // 速度硬门槛：装得下但慢到不可用，不该出现在推荐里
        let gated: Vec<&Model> = pool
            .iter()
            .copied()
            .filter(|m| self.est_tok_s(m) >= p.min_tok_s())
            .collect();
        if !gated.is_empty() {
            pool = gated;
        }

        pool.sort_by(|a, b| {
            self.score(b, p)
                .partial_cmp(&self.score(a, p))
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        pool.into_iter().take(limit).map(|m| self.advice(m)).collect()
    }

    /// 按用途给结论与理由
    pub fn match_purpose(&self, p: Purpose) -> Option<(Advice<'_>, String)> {
        let a = self.top_matches(p, 1).into_iter().next()?;
        let m = a.model;
        let mut reason = match self.benchmarks.get(m.name) {
            Some(v) => format!(
                "需 {:.1} GB，占预算 {:.0}%；本机实测 {:.1} tok/s",
                a.need_gb,
                a.ratio * 100.0,
                v
            ),
            None => format!(
                "需 {:.1} GB，占预算 {:.0}%；估算 {:.0} tok/s",
                a.need_gb,
                a.ratio * 100.0,
                a.est_tok_s
            ),
        };
        let mc = self.max_context(m);
        if mc > 0 {
            reason.push_str(&format!("；可开至 {}K 上下文", mc / 1024));
        }
        if a.level == FitLevel::Plenty {
            reason.push_str("；余量充足，可换 Q6/Q8 更高精度");
        }
        Some((a, reason))
    }

    /// 本机建议档位：在"流畅/余量充足"里取最大参数
    pub fn sweet_spot(&self) -> String {
        let best = MODELS
            .iter()
            .filter(|m| matches!(self.level(m), FitLevel::Smooth | FitLevel::Plenty))
            .max_by(|a, b| a.params_b.partial_cmp(&b.params_b).unwrap_or(std::cmp::Ordering::Equal));
        match best {
            Some(m) => {
                if m.active_b < m.params_b {
                    format!("≈{}B-A{}B", m.params_b as i64, m.active_b as i64)
                } else {
                    format!("≈{}B", m.params_b as i64)
                }
            }
            None => "—".to_string(),
        }
    }

    pub fn fit_count(&self) -> usize {
        MODELS
            .iter()
            .filter(|m| self.level(m) != FitLevel::TooHeavy)
            .count()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn adv() -> Advisor {
        // 本机实测基线：M5 Max 128GB，Metal 工作集 107.5 GB → 预算 102.4 GB；带宽 323 GB/s
        Advisor::new(102.4, 323.0, 16384)
    }

    fn model(name: &str) -> &'static Model {
        MODELS.iter().find(|m| m.name == name).unwrap()
    }

    #[test]
    fn catalog_matches_swift_count() {
        // 与 Swift 版 Sources/Catalog.swift 保持 79 条一致（单一权威源）
        assert_eq!(MODELS.len(), 79, "Rust catalog 应与 Swift 版 79 条一致");
    }

    #[test]
    fn non_chattable_categories_are_excluded_from_task_pool() {
        // 图像/语音/向量/重排不能当对话模型，任务候选池里不该出现
        let a = adv();
        let blend = TaskBlend::single(WorkTask::Daily);
        for adv in a.task_matches(&blend, 1000) {
            assert!(
                adv.model.cat.chattable(),
                "{} 是非对话分类，不该进任务候选",
                adv.model.name
            );
        }
    }

    #[test]
    fn need_matches_hand_calculation() {
        // gpt-oss 120B：62.4 权重 + 0.18×16 KV + 1.6 运行时 = 66.9
        let n = adv().need(model("gpt-oss 120B"));
        assert!((n - 66.9).abs() < 0.1, "need={n}");
    }

    #[test]
    fn moe_speed_uses_active_params_only() {
        let a = adv();
        // Qwen3.6 35B-A3B：base 24.5×0.25/36 ≈ 2.0 + 0.25 = 2.29 → 145.35/2.29 ≈ 63
        let tps = a.est_tok_s(model("Qwen3.6 35B-A3B"));
        assert!((55.0..70.0).contains(&tps), "MoE 估速={tps}，若被钳到 6B 会虚高到 120+");
        // 同体积 dense 必须显著更慢
        let dense = a.est_tok_s(model("Qwen3 32B"));
        assert!(dense < tps / 4.0, "dense={dense} MoE={tps}");
    }

    #[test]
    fn coding_prefers_fast_moe_over_slow_dense() {
        let a = adv();
        let (best, _) = a.match_purpose(Purpose::Coding).unwrap();
        assert_eq!(best.model.name, "Qwen3-Coder-Next 80B-A3B");
    }

    #[test]
    fn slow_models_are_excluded_from_recommendation() {
        let a = adv();
        let (best, _) = a.match_purpose(Purpose::Writing).unwrap();
        assert!(
            best.est_tok_s >= Purpose::Writing.min_tok_s(),
            "推荐了 {} tok/s 的模型，低于写作门槛",
            best.est_tok_s
        );
    }

    #[test]
    fn measured_value_overrides_estimate() {
        let mut a = adv();
        a.benchmarks
            .insert("Qwen2.5 14B".to_string(), 22.5);
        assert!((a.est_tok_s(model("Qwen2.5 14B")) - 22.5).abs() < 1e-9);
    }


    #[test]
    fn task_picks_match_swift_side() {
        // 与 Swift 版实跑结果对齐：同一台机器、同一套清单、同一套公式
        let a = Advisor::new(102.4, 323.0, 16384);
        let cases = [
            (WorkTask::Paper, "GLM-4.5-Air 106B"),
            (WorkTask::Coding, "Qwen3-Coder-Next 80B-A3B"),
            (WorkTask::Daily, "GLM-4.7-Flash 30B"),
            (WorkTask::Vision, "Qwen3-VL 30B-A3B"),
            (WorkTask::DataAnalysis, "gpt-oss 120B"),
        ];
        for (t, want) in cases {
            let blend = TaskBlend::single(t);
            let got = a.task_matches(&blend, 1);
            assert!(!got.is_empty(), "{} 无候选", t.label());
            assert_eq!(got[0].model.name, want, "{} 首选不一致", t.label());
        }
    }

    #[test]
    fn chinese_heavy_task_excludes_weak_chinese_models() {
        let a = Advisor::new(102.4, 323.0, 16384);
        let blend = TaskBlend::single(WorkTask::Paper);
        for adv in a.task_matches(&blend, 4) {
            assert!(
                capability_of(adv.model).zh >= 4.0,
                "{} 中文 {:.1} 不该出现在中文写作候选里",
                adv.model.name,
                capability_of(adv.model).zh
            );
        }
    }

    #[test]
    fn multi_task_blend_returns_something_and_reports_gates() {
        let a = Advisor::new(102.4, 323.0, 16384);
        let blend = TaskBlend::new(vec![WorkTask::Paper, WorkTask::Coding]);
        let (got, rep) = a.task_matches_with_report(&blend, 3);
        assert!(!got.is_empty(), "多选任务不该无解");
        assert!(rep.total > 0 && rep.passed > 0 && rep.passed <= rep.total,
                "门槛统计不合理 total={} passed={}", rep.total, rep.passed);
        assert!(rep.passed >= got.len());
        // 组合了编码任务，Coder 家族应被 family factor 拉回候选
        assert!(got.iter().any(|x| x.model.name.contains("Coder")) || got[0].model.name.contains("GLM"));
    }

    #[test]
    fn gate_report_marks_relaxed_speed_gate() {
        // 带宽低到不可能达标：速度门槛会把候选全砍光 → 必须放宽且账目显式标注
        let a = Advisor::new(102.4, 20.0, 16384);
        let blend = TaskBlend::single(WorkTask::Paper);
        let (got, rep) = a.task_matches_with_report(&blend, 3);
        assert!(!got.is_empty(), "放宽后仍应有结果，不能空手而归");
        assert!(rep.relaxed_speed, "速度门槛被放宽了却没标记");
        assert!(rep.accounting().contains("已放宽"), "账目里看不出放宽：{}", rep.accounting());
        assert_eq!(rep.warnings().len(), 1);
    }

    #[test]
    fn gate_report_not_relaxed_under_normal_bandwidth() {
        let a = Advisor::new(102.4, 320.0, 16384);
        let blend = TaskBlend::single(WorkTask::Paper);
        let (_, rep) = a.task_matches_with_report(&blend, 3);
        assert!(!rep.relaxed_speed && !rep.relaxed_chinese, "正常带宽下不该放宽门槛");
        // 未放宽时账目必须闭合
        assert_eq!(
            rep.total
                - rep.cut_modality
                - rep.cut_capacity
                - rep.cut_context
                - rep.cut_speed
                - rep.cut_chinese,
            rep.passed,
            "门槛账目不闭合：{}",
            rep.accounting()
        );
    }

    #[test]
    fn vision_task_never_returns_text_only_model() {
        let a = Advisor::new(102.4, 323.0, 16384);
        let blend = TaskBlend::single(WorkTask::Vision);
        for adv in a.task_matches(&blend, 3) {
            assert!(
                capability_of(adv.model).vision > 1.5,
                "{} 不具备图像理解能力，不该出现在图表理解候选里",
                adv.model.name
            );
        }
    }

    #[test]
    fn text_task_may_draw_from_vision_models() {
        // 反向保证：文本任务不该因为分类是"多模态"就把好模型排除掉
        let a = Advisor::new(102.4, 323.0, 16384);
        let blend = TaskBlend::single(WorkTask::Paper);
        let (_, rep) = a.task_matches_with_report(&blend, 4);
        assert!(
            rep.total > 40,
            "文本任务候选池被类别门砍得太窄（{}），多模态模型被误伤",
            rep.total
        );
    }

    #[test]
    fn long_doc_only_returns_128k_capable() {
        let a = Advisor::new(102.4, 323.0, 131072);
        for ad in a.top_matches(Purpose::LongDoc, 3) {
            assert!(a.max_context(ad.model) >= 131_072, "{} 放不下 128K", ad.model.name);
        }
    }
}

// ---------------------------------------------------------------- 任务级匹配

use crate::capability::{capability_of, Capability};
use crate::task::{TaskBlend, WorkTask};

/// 各道门槛的淘汰计数，用于在界面上解释"为什么没有结果"
///
/// 账目规则（重要）：`cut_*` 记录的是**这道门槛本会砍掉多少**，
/// 与「是否被放宽」无关；`relaxed_*` 说明该门槛砍光后是否被自动退回。
/// 因此 `total - cut_capacity - cut_context - cut_speed - cut_chinese` 只在
/// 没有被放宽时才等于 `passed`；界面上必须把放宽状态一并显示，
/// 否则会出现「-34 … 通过 19」这种自相矛盾的数字（本字段就是为了修这个）。
#[derive(Debug, Clone, Default)]
pub struct GateReport {
    pub total: usize,
    /// 模态门槛（"必须看图"）淘汰数；只有图表类任务会用到
    pub cut_modality: usize,
    pub cut_capacity: usize,
    pub cut_context: usize,
    pub cut_speed: usize,
    pub cut_chinese: usize,
    pub passed: usize,
    /// 速度门槛把候选全砍光了，已自动放宽（否则用户永远拿不到结果）
    pub relaxed_speed: bool,
    /// 中文门槛把候选全砍光了，已自动放宽
    pub relaxed_chinese: bool,
}

impl GateReport {
    /// 一行可核对的门槛账；放宽的门槛显式标 `(已放宽)`
    pub fn accounting(&self) -> String {
        let sp = if self.relaxed_speed { "(已放宽)" } else { "" };
        let zh = if self.relaxed_chinese { "(已放宽)" } else { "" };
        format!(
            "候选 {} → 模态 -{} → 容量 -{} → 上下文 -{} → 速度 -{}{} → 中文 -{}{} → 通过 {}",
            self.total,
            self.cut_modality,
            self.cut_capacity,
            self.cut_context,
            self.cut_speed,
            sp,
            self.cut_chinese,
            zh,
            self.passed
        )
    }

    /// 有门槛被放宽时给出人话解释
    pub fn warnings(&self) -> Vec<String> {
        let mut v = Vec::new();
        if self.relaxed_speed {
            v.push(format!(
                "速度门槛把所有 {} 个候选都砍光了，已自动放宽——本机跑这些模型会偏慢",
                self.cut_speed
            ));
        }
        if self.relaxed_chinese {
            v.push(format!(
                "中文门槛把所有 {} 个候选都砍光了，已自动放宽——中文表现可能不达标",
                self.cut_chinese
            ));
        }
        v
    }
}

impl Advisor {
    /// 七维加权平均（1–5），权重由任务组合给出（已归一化）
    pub fn capability_score(&self, m: &Model, blend: &TaskBlend) -> f64 {
        let c: Capability = capability_of(m);
        let w = blend.weights();
        let sum: f64 = w.iter().sum();
        if sum <= 0.0 {
            return 0.0;
        }
        let dot: f64 = c.vector().iter().zip(w.iter()).map(|(a, b)| a * b).sum();
        dot / sum
    }

    /// 家族修正：code-tuned 模型文字偏干，写作类任务降权；编码类任务升权
    pub fn family_factor(&self, m: &Model, blend: &TaskBlend) -> f64 {
        let n = m.name.to_lowercase();
        let coder = n.contains("coder") || n.contains("devstral");
        if blend.tasks.is_empty() {
            return 1.0;
        }
        let mut acc = 0.0;
        for t in &blend.tasks {
            acc += match t {
                WorkTask::Coding | WorkTask::Debugging | WorkTask::AffectExp => {
                    if coder { 1.06 } else { 0.96 }
                }
                WorkTask::Paper
                | WorkTask::Teaching
                | WorkTask::Daily
                | WorkTask::PeerReview
                | WorkTask::Summarize
                | WorkTask::Translation => {
                    if coder { 0.88 } else { 1.0 }
                }
                _ => 1.0,
            };
        }
        acc / blend.tasks.len() as f64
    }

    /// 能力为主，速度达门槛两倍即不再加分
    pub fn task_score(&self, m: &Model, blend: &TaskBlend) -> f64 {
        let cap = self.capability_score(m, blend);
        let speed_ok = (self.est_tok_s(m) / (blend.min_tok_s() * 2.0).max(1.0)).min(1.0);
        cap * (0.88 + 0.12 * speed_ok) * self.family_factor(m, blend)
    }

    /// 任务级候选池。
    ///
    /// 只有「必须看图」的任务才按模态收窄；其余任务**不限类别**——
    /// 多模态模型同样是称职的文本模型，按类别乱砍会白白丢掉好候选
    /// （例如 Qwen3-VL 30B-A3B 写作与中文都不弱，不该因为分类是"多模态"就被排除）。
    fn pool_for(&self, blend: &TaskBlend, rep: &mut GateReport) -> Vec<&'static Model> {
        let base: Vec<&'static Model> = MODELS.iter().filter(|m| m.cat.chattable()).collect();
        rep.total = base.len();
        let needs_vision = blend.categories().contains(&Category::Vision);
        let pool: Vec<&'static Model> = base
            .into_iter()
            .filter(|m| !needs_vision || capability_of(m).vision > 1.5)
            .collect();
        rep.cut_modality = rep.total - pool.len();
        pool
    }

    /// 任务级候选：两道硬门（容量/上下文 → 速度 → 中文）后按能力加权排序
    pub fn task_matches_with_report(
        &self,
        blend: &TaskBlend,
        limit: usize,
    ) -> (Vec<Advice<'static>>, GateReport) {
        let mut rep = GateReport::default();
        let pool = self.pool_for(blend, &mut rep);

        let mut cur: Vec<&'static Model> = pool;
        let after_cap: Vec<&'static Model> = cur
            .iter()
            .copied()
            .filter(|m| self.level(m) != FitLevel::TooHeavy)
            .collect();
        rep.cut_capacity = cur.len() - after_cap.len();
        cur = after_cap;

        let after_ctx: Vec<&'static Model> = cur
            .iter()
            .copied()
            .filter(|m| self.max_context(m) >= blend.min_context())
            .collect();
        rep.cut_context = cur.len() - after_ctx.len();
        cur = after_ctx;

        let after_speed: Vec<&'static Model> = cur
            .iter()
            .copied()
            .filter(|m| self.est_tok_s(m) >= blend.min_tok_s())
            .collect();
        rep.cut_speed = cur.len() - after_speed.len();
        // 速度门槛若把所有候选都砍光，则退回上一级（否则用户永远拿不到结果）
        if after_speed.is_empty() && !cur.is_empty() {
            rep.relaxed_speed = true;
        } else {
            cur = after_speed;
        }

        if blend.chinese_heavy() {
            let after_zh: Vec<&'static Model> = cur
                .iter()
                .copied()
                .filter(|m| capability_of(m).zh >= 4.0)
                .collect();
            rep.cut_chinese = cur.len() - after_zh.len();
            if after_zh.is_empty() && !cur.is_empty() {
                rep.relaxed_chinese = true;
            } else {
                cur = after_zh;
            }
        }

        rep.passed = cur.len();
        cur.sort_by(|a, b| {
            self.task_score(b, blend)
                .partial_cmp(&self.task_score(a, blend))
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        (
            cur.into_iter().take(limit).map(|m| self.advice(m)).collect(),
            rep,
        )
    }

    pub fn task_matches(&self, blend: &TaskBlend, limit: usize) -> Vec<Advice<'static>> {
        self.task_matches_with_report(blend, limit).0
    }

    /// 结论配一句可核对的话
    pub fn task_reason(&self, a: &Advice<'_>, blend: &TaskBlend) -> String {
        let c = capability_of(a.model);
        let mut s = format!(
            "能力加权 {:.2}/5（中文 {:.1} · 写作 {:.1} · 代码 {:.1} · 数理 {:.1} · 指令 {:.1}）",
            self.capability_score(a.model, blend),
            c.zh,
            c.writing,
            c.code,
            c.math,
            c.follow
        );
        match self.benchmarks.get(a.model.name) {
            Some(v) => s.push_str(&format!(
                "；需 {:.1} GB，占预算 {:.0}%；实测 {:.1} tok/s",
                a.need_gb,
                a.ratio * 100.0,
                v
            )),
            None => s.push_str(&format!(
                "；需 {:.1} GB，占预算 {:.0}%；估算 {:.0} tok/s",
                a.need_gb,
                a.ratio * 100.0,
                a.est_tok_s
            )),
        }
        let mc = self.max_context(a.model);
        if mc > 0 {
            s.push_str(&format!("；可开至 {}K", mc / 1024));
        }
        s
    }
}
