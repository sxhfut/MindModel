//! 七维能力画像。
//!
//! **这是按模型家族与规模推导的编辑先验，不是公开基准测试分数。**
//! 用途仅限：同一台机器上"都跑得动"的候选之间做取舍；不可用于跨硬件或对外宣称性能。

use crate::advisor::{Category, Model};

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Capability {
    pub zh: f64,
    pub writing: f64,
    pub code: f64,
    pub math: f64,
    pub tools: f64,
    pub vision: f64,
    pub follow: f64,
}

impl Default for Capability {
    fn default() -> Self {
        Self {
            zh: 3.0,
            writing: 3.0,
            code: 3.0,
            math: 3.0,
            tools: 3.0,
            vision: 1.0,
            follow: 3.0,
        }
    }
}

impl Capability {
    pub fn vector(&self) -> [f64; 7] {
        [self.zh, self.writing, self.code, self.math, self.tools, self.vision, self.follow]
    }

    pub fn get(&self, i: usize) -> f64 {
        self.vector()[i]
    }
}

fn clamp5(v: f64) -> f64 {
    v.clamp(1.0, 5.0)
}

const ZH_STRONG: [&str; 8] = [
    "qwen", "glm", "ernie", "deepseek", "hunyuan", "minicpm", "internlm", "yi 1.5",
];

pub fn capability_of(m: &Model) -> Capability {
    let n = m.name.to_lowercase();
    let mut c = Capability::default();

    // 家族先验：中文
    c.zh = if ZH_STRONG.iter().any(|k| n.contains(k)) { 4.6 } else { 3.0 };
    if n.contains("gemma") {
        c.zh = 3.8;
    }
    if n.contains("llama") || n.contains("mistral") || n.contains("mixtral") {
        c.zh = 2.8;
    }

    // 规模带来的通用能力：0.3B → 2.2，120B → 4.4
    let tier = (m.params_b.max(0.3).log10() / 120.0_f64.log10()).clamp(0.0, 1.0);
    let general = 2.2 + 2.2 * tier;

    let coder_family = n.contains("coder") || n.contains("devstral");
    c.writing = general * if coder_family { 0.75 } else { 1.0 };
    c.code = if coder_family { 4.8 } else { general * 0.85 };
    c.math = if m.cat == Category::Reason { 4.7 } else { general * 0.8 };
    c.tools = if m.cat == Category::Agent { 4.7 } else { general * 0.75 };
    c.vision = if m.cat == Category::Vision { 4.7 } else { 1.0 };
    c.follow = general * 0.95;

    // 家族微调
    if n.contains("glm") {
        c.zh = 4.8;
        c.tools += 0.3;
    }
    if n.contains("deepseek") {
        c.math += 0.4;
    }
    if n.contains("gemma") {
        c.writing += 0.3;
    }
    if n.contains("granite") {
        c.follow += 0.3;
    }
    if n.contains("nemotron") {
        c.tools += 0.4;
    }
    if m.cat == Category::Embed {
        c = Capability {
            zh: 1.0,
            writing: 1.0,
            code: 1.0,
            math: 1.0,
            tools: 1.0,
            vision: 1.0,
            follow: 1.0,
        };
    }

    Capability {
        zh: clamp5(c.zh),
        writing: clamp5(c.writing),
        code: clamp5(c.code),
        math: clamp5(c.math),
        tools: clamp5(c.tools),
        vision: clamp5(c.vision),
        follow: clamp5(c.follow),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::catalog::MODELS;

    fn m(name: &str) -> &'static Model {
        MODELS.iter().find(|x| x.name == name).unwrap()
    }

    #[test]
    fn chinese_families_rank_higher_on_zh() {
        assert!(capability_of(m("GLM-4.5-Air 106B")).zh > capability_of(m("Nemotron 3 Super 120B-A12B")).zh);
        assert!(capability_of(m("Qwen3.6 35B-A3B")).zh >= 4.0);
        assert!(capability_of(m("Llama 3.3 70B")).zh < 3.0);
    }

    #[test]
    fn coder_family_trades_prose_for_code() {
        let c = capability_of(m("Qwen3-Coder-Next 80B-A3B"));
        assert!(c.code >= 4.5, "code={}", c.code);
        assert!(c.writing < c.code, "coder 应当写作弱于代码");
    }

    #[test]
    fn scores_are_clamped() {
        for x in MODELS {
            for v in capability_of(x).vector() {
                assert!((1.0..=5.0).contains(&v), "{} 越界 {}", x.name, v);
            }
        }
    }
}
