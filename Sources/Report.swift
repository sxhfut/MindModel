import Foundation

// MARK: - 导出报告的纯格式化逻辑

/// 从 AppState 里抽出来的纯函数：不依赖 UI、不读硬件，可以单独编译复核。
/// 报告是对外交付物，落款不能只写工具名——出品单位、带领者、联系方式都要带。
enum Report {
    /// 固定 POSIX 区域 + 公历：系统日历若被设成农历/佛历，裸 DateFormatter
    /// 会写出非预期年份；导出的是对外文档，时间格式必须稳定。
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = format
        return f
    }

    /// 人能读的导出时间（直接写 Date() 会带 +0000 与毫秒）
    static var stamp: String { formatter("yyyy-MM-dd HH:mm:ss").string(from: Date()) }

    /// 表格里的记录时间（实测记录 / 长上下文记录）
    static func recordStamp(_ date: Date) -> String {
        formatter("yyyy-MM-dd HH:mm").string(from: date)
    }

    /// 固定落款，与「关于」页共用 LabInfo，改署名只改一处
    static var footer: String {
        "\n---\n\n"
            + "出品：\(LabInfo.university) · \(LabInfo.lab)\n"
            + "带领者：\(LabInfo.leadName)（\(LabInfo.labSite)）\n"
            + "联系：\(LabInfo.email) · \(LabInfo.contactPage)\n"
            + "由 MindModel \(LabInfo.version) 生成 · 许可 \(LabInfo.license)\n"
            + "\(LabInfo.copyright)\n"
    }
}
