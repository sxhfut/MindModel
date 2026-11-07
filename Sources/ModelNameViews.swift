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
struct TermDictionarySheet: View {
    @Environment(\.dismiss) var dismiss

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
