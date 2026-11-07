import SwiftUI

// MARK: - 模型名术语解读的 UI 组件

/// 单个术语 token：小徽章样式，hover 显示中文解释。
struct TermChip: View {
    let token: TermToken

    var color: Color {
        switch token.kind {
        case .params: return T.accent
        case .capability: return T.good
        case .quant: return Color(red: 0.60, green: 0.48, blue: 0.92)
        case .precision: return Color(red: 0.42, green: 0.70, blue: 0.96)
        case .format: return Color.secondary
        default: return Color.secondary
        }
    }

    var body: some View {
        Text(token.text)
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.14))
            .foregroundStyle(color)
            .clipShape(Capsule())
            .help("\(token.text)：\(token.explain)")
    }
}

/// 一行可读规格：把模型名翻译成人话（术语 chips + 每个可 hover 解释）。
struct NameSpecRow: View {
    let name: String

    var body: some View {
        let tokens = ModelNameDecoder.decode(name)
        if tokens.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 5) {
                ForEach(tokens.prefix(5)) { t in
                    TermChip(token: t)
                }
            }
        }
    }
}

/// 模型名下方的「术语解读」行：chips + 问号（点开完整词典）。
struct NameDecodeLine: View {
    @EnvironmentObject var s: AppState
    let name: String

    var body: some View {
        let tokens = ModelNameDecoder.decode(name)
        if tokens.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 5) {
                ForEach(tokens.prefix(5)) { t in
                    TermChip(token: t)
                }
                Button {
                    s.showTermDict = true
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("查看模型名术语完整解释")
            }
        }
    }
}

/// 完整术语词典弹层：按类别分组列出所有术语及其解释。
struct TermDictionarySheet: View {    @Environment(\.dismiss) var dismiss

    private var grouped: [(TermKind, [TermEntry])] {
        let order: [TermKind] = [.capability, .quant, .precision, .other]
        var result: [(TermKind, [TermEntry])] = []
        for k in order {
            let entries = ModelNameDecoder.allTerms.filter { $0.kind == k }
            if !entries.isEmpty { result.append((k, entries)) }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("模型名术语说明").font(.system(size: 16, weight: .semibold))
                    Text("看懂名字里那一串缩写到底代表什么").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }.buttonStyle(.bordered).controlSize(.small)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(grouped, id: \.0) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.0.rawValue)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(T.accent)
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(group.1) { e in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(e.label)
                                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                            .frame(width: 78, alignment: .leading)
                                            .foregroundStyle(.primary)
                                        Text(e.explain)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Spacer()
                                    }
                                }
                            }
                            Divider()
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(18)
        .frame(width: 560, height: 520)
    }
}

// MARK: - 本机适配与性能预估 UI

/// 适配档位徽章（余量充足 / 流畅 / 可运行 / 偏紧 / 超出预算）。
struct FitBadge: View {
    let fit: OnlineFit

    var body: some View {
        Text(fit.level.label)
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(fitColor(fit.level).opacity(0.16))
            .foregroundStyle(fitColor(fit.level))
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(fitColor(fit.level).opacity(0.32), lineWidth: 0.6))
            .help("\(fit.verdict)\n\(fit.summary)")
    }
}

/// 内存占用条：本机预算为底，本模型所需为填充。
struct FitGauge: View {
    let fit: OnlineFit
    let budgetGB: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let pct = min(1.0, max(0.0, fit.needGB / max(1.0, budgetGB)))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(fitColor(fit.level))
                    .frame(width: max(2, w * pct))
            }
        }
        .frame(width: 56, height: 4)
        .help(String(format: "本模型约需 %.1f GB / 本机可用 %.0f GB", fit.needGB, budgetGB))
    }
}

/// 一行完整的「本机适配 + 性能表现」说明。
/// 例：`[流畅] ▬▬▬ 需 9.2GB / 128GB · 估 42 tok/s · 可开 64K`
struct FitLine: View {
    let fit: OnlineFit
    let budgetGB: Double

    var body: some View {
        HStack(spacing: 6) {
            FitBadge(fit: fit)
            FitGauge(fit: fit, budgetGB: budgetGB)
            Text(String(format: "需 %.1f / %.0f GB", fit.needGB, budgetGB))
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
            if fit.showSpeed {
                Text(String(format: "· 约 %.0f tok/s · %@", fit.estTokS, fit.speed.label))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(speedColor(fit.speed))
            } else if fit.specUnknown && fit.level != .tooHeavy {
                Text("· 速度无法估算")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("只拿到了文件体积，模型名里没有参数量——分不清是稠密还是 MoE，速度就不硬给一个数")
            }
            if fit.maxContextK > 0 {
                Text("· 可开 \(fit.maxContextK)K")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if fit.shards > 1 {
                Text("· \(fit.shards) 片合计")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help("分片模型的单片体积不等于模型体积，这里已按总片数合并估算")
            }
            if !fit.exactWeight || !fit.fromCatalog {
                Text("· 估算")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .help(fit.specUnknown
                          ? "体积是真实文件大小；参数量未知，所以没算 KV cache 与速度"
                          : (fit.exactWeight
                             ? "体积取自真实文件大小；KV/速度按参数量推算"
                             : "体积与速度均按模型名推算，实际以下载后为准"))
            }
        }
    }

    func speedColor(_ g: SpeedGrade) -> Color {
        switch g {
        case .fast: return T.good
        case .ok: return Color(red: 0.42, green: 0.70, blue: 0.96)
        case .slow: return T.warn
        case .crawl: return T.bad
        }
    }
}

/// 无法给出任何评估时的说明行。
/// 空着不写会被当成程序算错了，所以这里必须明说「缺什么依据」，并强调不等于跑不动。
struct FitUnknownLine: View {
    /// 缺依据的具体原因（默认：名字里没有参数量）
    var reason: String = "模型名里没有参数量，仓库列表也没给文件体积"

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "questionmark.circle").font(.system(size: 10))
            Text("无法估算本机表现")
                .font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12))
                .foregroundStyle(.secondary)
                .clipShape(Capsule())
            Text("· \(reason)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("· 不代表跑不动")
                .font(.system(size: 11))
                .foregroundStyle(.secondary.opacity(0.75))
        }
        .help("""
        在线搜索只给模型名。名字里带 7B / 30B-A3B 这类参数量，才能推出体积、内存占用和速度；\
        这条既没有参数量、也没有文件体积，硬算就是编数字，所以这里不下结论。
        想准确判断：点「下载」列出文件，有了真实体积就能判内存；下载完成后再看实测速度。
        """)
    }
}

/// 超出预算时的醒目提示条。
struct FitWarnBar: View {
    let fit: OnlineFit

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
            Text("需要 \(String(format: "%.1f", fit.needGB)) GB，超出本机可用内存，本地跑不动")
                .font(.system(size: 11))
        }
        .foregroundStyle(T.bad)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(T.bad.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
