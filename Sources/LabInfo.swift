import Foundation

// MARK: - 实验室署名与联系方式（纯数据，供关于页 / 导出报告共用）

/// 署名与联系方式**照录实验室官网公开内容**，不要凭印象填。
/// 来源：
///   https://sxhfut.github.io/          实验室全称、英文名、带领者
///   https://sxhfut.github.io/contact/ 邮箱、通讯地址、教师主页、GitHub
/// 官网没有电话、邮编、微信公众号，所以这里也不列（不编）。
///
/// 注意：「出品」与「版权」是两个不同来源的原文，不要互相覆盖：
///   - 实验室主站写「合肥工业大学多模态情感计算与人因工程实验室，由孙晓教授带领」
///   - 本项目的 README / 项目主页页脚一直写「多模态情感计算与人因工程团队」
/// 这里按各自原文分列，避免把一种写法硬改成另一种。

enum LabInfo {
    static let university = "合肥工业大学"
    static let universityEN = "Hefei University of Technology (HFUT)"
    static let lab = "多模态情感计算与人因工程实验室"
    static let labEN = "Multimodal Affective Computing and Human Factors Engineering Laboratory"
    /// 官网原文是「由孙晓教授带领」，不是「负责人：」字段，措辞上不冒充官方字段
    static let leadName = "孙晓 教授"
    static let lead = leadName + "（官网：由孙晓教授带领）"
    static let email = "sunx@hfut.edu.cn"
    static let address = "安徽省合肥市屯溪路 193 号，合肥工业大学计算机与信息学院"
    static let addressEN = "School of Computer Science and Information Engineering, HFUT, 193 Tunxi Road, Hefei, Anhui, China"

    static let labSite = "https://sxhfut.github.io/"
    static let contactPage = "https://sxhfut.github.io/contact/"
    static let facultyPage = "https://faculty.hfut.edu.cn/sunxiao/zh_CN/index.htm"
    static let labGitHub = "https://github.com/sxhfut"
    static let repo = "https://github.com/sxhfut/MindModel"
    static let projectPage = "https://sxhfut.github.io/MindModel/"

    /// 项目主页 / README / Info.plist 里沿用的版权主体
    static let copyright = "Copyright 2026 多模态情感计算与人因工程团队"
    static let license = "Apache-2.0"

    static var version: String {
        let d = Bundle.main.infoDictionary
        let short = d?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = d?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}
