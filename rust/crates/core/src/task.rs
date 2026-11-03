//! 角色与任务：任务决定能力权重，多选任务按权重归一化后取均值、门槛取最严。

use crate::advisor::Category;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkRole {
    Researcher,
    Engineer,
    Teacher,
    Student,
    Manager,
    Creator,
}

impl WorkRole {
    pub fn label(&self) -> &'static str {
        match self {
            WorkRole::Researcher => "研究者",
            WorkRole::Engineer => "工程师",
            WorkRole::Teacher => "教师",
            WorkRole::Student => "学生",
            WorkRole::Manager => "管理者",
            WorkRole::Creator => "内容创作",
        }
    }

    pub fn all() -> [WorkRole; 6] {
        [
            WorkRole::Researcher,
            WorkRole::Engineer,
            WorkRole::Teacher,
            WorkRole::Student,
            WorkRole::Manager,
            WorkRole::Creator,
        ]
    }

    pub fn tasks(&self) -> &'static [WorkTask] {
        match self {
            WorkRole::Researcher => &[
                WorkTask::Paper,
                WorkTask::LitReview,
                WorkTask::DataAnalysis,
                WorkTask::AffectExp,
                WorkTask::PeerReview,
                WorkTask::Summarize,
                WorkTask::Vision,
            ],
            WorkRole::Engineer => &[
                WorkTask::Coding,
                WorkTask::Debugging,
                WorkTask::DataAnalysis,
                WorkTask::Summarize,
                WorkTask::Vision,
                WorkTask::Daily,
            ],
            WorkRole::Teacher => &[
                WorkTask::Teaching,
                WorkTask::Paper,
                WorkTask::Translation,
                WorkTask::Summarize,
                WorkTask::Vision,
                WorkTask::Daily,
            ],
            WorkRole::Student => &[
                WorkTask::Paper,
                WorkTask::LitReview,
                WorkTask::Coding,
                WorkTask::Translation,
                WorkTask::Summarize,
                WorkTask::Daily,
            ],
            WorkRole::Manager => &[
                WorkTask::Summarize,
                WorkTask::DataAnalysis,
                WorkTask::Daily,
                WorkTask::Translation,
                WorkTask::Vision,
                WorkTask::Paper,
            ],
            WorkRole::Creator => &[
                WorkTask::Paper,
                WorkTask::Translation,
                WorkTask::Summarize,
                WorkTask::Daily,
                WorkTask::Vision,
            ],
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum WorkTask {
    Paper,
    LitReview,
    Coding,
    Debugging,
    DataAnalysis,
    PeerReview,
    Teaching,
    Translation,
    AffectExp,
    Daily,
    Vision,
    Summarize,
}

impl WorkTask {
    /// 全部任务，固定顺序（与 Swift 版 WorkTask.allCases 一致）
    pub fn all() -> [WorkTask; 12] {
        [
            WorkTask::Paper,
            WorkTask::LitReview,
            WorkTask::Coding,
            WorkTask::Debugging,
            WorkTask::DataAnalysis,
            WorkTask::PeerReview,
            WorkTask::Teaching,
            WorkTask::Translation,
            WorkTask::AffectExp,
            WorkTask::Daily,
            WorkTask::Vision,
            WorkTask::Summarize,
        ]
    }

    /// CLI / API 用的短键（paper/lit/code/...），与 Swift 侧 key 一致
    pub fn key(&self) -> &'static str {
        match self {
            WorkTask::Paper => "paper",
            WorkTask::LitReview => "lit",
            WorkTask::Coding => "code",
            WorkTask::Debugging => "debug",
            WorkTask::DataAnalysis => "data",
            WorkTask::PeerReview => "review",
            WorkTask::Teaching => "teach",
            WorkTask::Translation => "trans",
            WorkTask::AffectExp => "affect",
            WorkTask::Daily => "daily",
            WorkTask::Vision => "vision",
            WorkTask::Summarize => "summary",
        }
    }

    /// 从短键解析任务；返回 None 表示不认识的键（调用方自行决定忽略或报错）
    pub fn from_key(name: &str) -> Option<WorkTask> {
        Some(match name.trim() {
            "paper" => WorkTask::Paper,
            "lit" | "litreview" => WorkTask::LitReview,
            "code" | "coding" => WorkTask::Coding,
            "debug" | "debugging" => WorkTask::Debugging,
            "data" | "dataanalysis" => WorkTask::DataAnalysis,
            "review" | "peerreview" => WorkTask::PeerReview,
            "teach" | "teaching" => WorkTask::Teaching,
            "trans" | "translation" => WorkTask::Translation,
            "affect" | "affectexp" => WorkTask::AffectExp,
            "daily" => WorkTask::Daily,
            "vision" => WorkTask::Vision,
            "summary" | "summarize" => WorkTask::Summarize,
            _ => return None,
        })
    }

    pub fn label(&self) -> &'static str {
        match self {
            WorkTask::Paper => "论文写作",
            WorkTask::LitReview => "文献调研",
            WorkTask::Coding => "代码实现",
            WorkTask::Debugging => "调试与重构",
            WorkTask::DataAnalysis => "数据分析",
            WorkTask::PeerReview => "审稿意见",
            WorkTask::Teaching => "教学备课",
            WorkTask::Translation => "翻译校对",
            WorkTask::AffectExp => "情感计算实验",
            WorkTask::Daily => "日常问答",
            WorkTask::Vision => "图表截图理解",
            WorkTask::Summarize => "长文总结",
        }
    }

    /// 七维原始权重：中文、写作、代码、数理、工具、视觉、长上下文
    pub fn raw_weights(&self) -> [f64; 7] {
        match self {
            WorkTask::Paper => [0.22, 0.38, 0.02, 0.14, 0.10, 0.02, 0.12],
            WorkTask::LitReview => [0.18, 0.26, 0.04, 0.10, 0.22, 0.04, 0.16],
            WorkTask::Coding => [0.04, 0.02, 0.52, 0.12, 0.24, 0.00, 0.06],
            WorkTask::Debugging => [0.04, 0.02, 0.48, 0.20, 0.20, 0.00, 0.06],
            WorkTask::DataAnalysis => [0.08, 0.04, 0.28, 0.42, 0.12, 0.00, 0.06],
            WorkTask::PeerReview => [0.18, 0.24, 0.04, 0.18, 0.24, 0.00, 0.12],
            WorkTask::Teaching => [0.26, 0.32, 0.06, 0.10, 0.14, 0.04, 0.08],
            WorkTask::Translation => [0.28, 0.26, 0.02, 0.04, 0.14, 0.00, 0.26],
            WorkTask::AffectExp => [0.16, 0.06, 0.30, 0.30, 0.12, 0.02, 0.04],
            WorkTask::Daily => [0.34, 0.22, 0.04, 0.06, 0.18, 0.02, 0.14],
            WorkTask::Vision => [0.14, 0.06, 0.02, 0.04, 0.10, 0.58, 0.06],
            WorkTask::Summarize => [0.16, 0.20, 0.02, 0.04, 0.28, 0.02, 0.28],
        }
    }

    pub fn min_context(&self) -> u32 {
        match self {
            WorkTask::Coding | WorkTask::Debugging | WorkTask::AffectExp => 32_768,
            WorkTask::Paper
            | WorkTask::LitReview
            | WorkTask::PeerReview
            | WorkTask::Summarize
            | WorkTask::Translation => 65_536,
            WorkTask::Teaching | WorkTask::DataAnalysis | WorkTask::Daily | WorkTask::Vision => {
                16_384
            }
        }
    }

    pub fn min_tok_s(&self) -> f64 {
        match self {
            WorkTask::Paper | WorkTask::Teaching => 12.0,
            WorkTask::Summarize | WorkTask::LitReview | WorkTask::PeerReview => 15.0,
            WorkTask::Coding | WorkTask::Debugging => 15.0,
            WorkTask::Daily => 28.0,
            WorkTask::DataAnalysis | WorkTask::AffectExp => 8.0,
            WorkTask::Translation => 10.0,
            WorkTask::Vision => 10.0,
        }
    }

    pub fn chinese_heavy(&self) -> bool {
        matches!(
            self,
            WorkTask::Paper
                | WorkTask::LitReview
                | WorkTask::PeerReview
                | WorkTask::Teaching
                | WorkTask::Translation
                | WorkTask::Summarize
                | WorkTask::Daily
        )
    }

    pub fn categories(&self) -> &'static [Category] {
        match self {
            WorkTask::Coding | WorkTask::Debugging => &[Category::Code, Category::Agent],
            WorkTask::Vision => &[Category::Vision],
            WorkTask::DataAnalysis | WorkTask::AffectExp => {
                &[Category::Code, Category::Reason, Category::Chat]
            }
            WorkTask::Daily => &[Category::Light, Category::Chat, Category::Agent],
            _ => &[Category::Chat, Category::Code],
        }
    }

    pub fn rationale(&self) -> &'static str {
        match self {
            WorkTask::Paper => "写作权重最高，中文语感次之；上下文要够长",
            WorkTask::LitReview => "看指令遵循与长上下文，能不能扛住几十篇文献",
            WorkTask::Coding => "代码能力为主，工具调用次之",
            WorkTask::Debugging => "代码 + 数理推理并重，要能顺着报错推",
            WorkTask::DataAnalysis => "数理推理为主，代码是实现手段",
            WorkTask::PeerReview => "指令遵循与数理判断并重，中文表达次之",
            WorkTask::Teaching => "中文表达与结构化写作",
            WorkTask::Translation => "双语语感与格式一致性",
            WorkTask::AffectExp => "数理 + 代码，跑实验多于写作",
            WorkTask::Daily => "响应速度与指令遵循优先，规模不必大",
            WorkTask::Vision => "图像理解为主，其余维度只做兜底",
            WorkTask::Summarize => "长上下文与要点提炼",
        }
    }
}

pub const DIM_LABELS: [&str; 7] = ["中文", "写作", "代码", "数理", "指令", "视觉", "长文"];

/// 多选任务的合并结果。
///
/// 合并规则（有意为之）：
/// - 权重：每个任务先归一化到 sum=1，再对选中任务取均值 —— 让"权重"可比
/// - 上下文门槛：取**最大** —— 组合里有一个需要 64K，就必须能撑 64K
/// - 速度门槛：取**最高** —— 组合里有一个要求 28 tok/s，就按 28 筛
/// - 中文门槛：任一任务中文为要 → 即视为中文任务
#[derive(Debug, Clone)]
pub struct TaskBlend {
    pub tasks: Vec<WorkTask>,
}

impl TaskBlend {
    pub fn new(tasks: Vec<WorkTask>) -> Self {
        Self { tasks }
    }

    pub fn single(t: WorkTask) -> Self {
        Self { tasks: vec![t] }
    }

    pub fn weights(&self) -> [f64; 7] {
        let mut acc = [0.0f64; 7];
        if self.tasks.is_empty() {
            return acc;
        }
        for t in &self.tasks {
            let raw = t.raw_weights();
            let sum: f64 = raw.iter().sum();
            if sum <= 0.0 {
                continue;
            }
            for i in 0..7 {
                acc[i] += raw[i] / sum;
            }
        }
        let n = self.tasks.len() as f64;
        for v in acc.iter_mut() {
            *v /= n;
        }
        acc
    }

    pub fn min_context(&self) -> u32 {
        self.tasks.iter().map(|t| t.min_context()).max().unwrap_or(16_384)
    }

    pub fn min_tok_s(&self) -> f64 {
        self.tasks
            .iter()
            .map(|t| t.min_tok_s())
            .fold(0.0_f64, f64::max)
    }

    pub fn chinese_heavy(&self) -> bool {
        self.tasks.iter().any(|t| t.chinese_heavy())
    }

    pub fn categories(&self) -> Vec<Category> {
        let mut v: Vec<Category> = Vec::new();
        for t in &self.tasks {
            for c in t.categories() {
                if !v.contains(c) {
                    v.push(*c);
                }
            }
        }
        v
    }

    pub fn label(&self) -> String {
        if self.tasks.is_empty() {
            "未选任务".to_string()
        } else {
            self.tasks
                .iter()
                .map(|t| t.label())
                .collect::<Vec<_>>()
                .join(" + ")
        }
    }

    /// 权重最高的前 n 个维度，用于在界面上解释"为什么是它"
    pub fn top_dimensions(&self, n: usize) -> Vec<(&'static str, f64)> {
        let w = self.weights();
        let mut v: Vec<(&'static str, f64)> = DIM_LABELS.iter().copied().zip(w.into_iter()).collect();
        v.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
        v.into_iter().take(n).filter(|(_, x)| *x > 0.0).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blended_weights_are_normalized() {
        let b = TaskBlend::new(vec![WorkTask::Paper, WorkTask::Vision]);
        let w = b.weights();
        let sum: f64 = w.iter().sum();
        assert!((sum - 1.0).abs() < 1e-9, "sum={sum}");
    }

    #[test]
    fn multi_select_takes_strictest_gates() {
        let b = TaskBlend::new(vec![WorkTask::Daily, WorkTask::Paper]);
        assert_eq!(b.min_context(), 65_536, "上下文取最严");
        assert!((b.min_tok_s() - 28.0).abs() < 1e-9, "速度取最高");
        assert!(b.chinese_heavy());
    }

    #[test]
    fn single_task_blend_equals_task_weights() {
        let b = TaskBlend::single(WorkTask::Coding);
        let w = b.weights();
        let raw = WorkTask::Coding.raw_weights();
        let sum: f64 = raw.iter().sum();
        for i in 0..7 {
            assert!((w[i] - raw[i] / sum).abs() < 1e-9);
        }
    }
}
