import SwiftUI
import AppKit

// MARK: - 关于 / 出品 页

struct AboutView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                HStack(alignment: .top, spacing: 16) {
                    appIcon
                    VStack(alignment: .leading, spacing: 5) {
                        Text("MindModel").font(.system(size: 22, weight: .bold, design: .rounded))
                        Text("本机大模型选型顾问 · 免费 · 开源 · 可离线")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                        Text("选型计算全在本机，不上传任何本机数据；仅主动搜索/下载在线模型时联网。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Text("版本 \(LabInfo.version) · 许可 \(LabInfo.license)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary.opacity(0.85))
                            .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHead(title: "出品", sub: "署名照录实验室官网原文")
                    KeyRow(k: "出品单位", v: LabInfo.university)
                    KeyRow(k: "", v: LabInfo.universityEN)
                    KeyRow(k: "实验室", v: LabInfo.lab)
                    KeyRow(k: "", v: LabInfo.labEN)
                    KeyRow(k: "带领者", v: LabInfo.lead)
                    KeyRow(k: "版权", v: LabInfo.copyright)
                    Text("「出品」用实验室官网的写法；「版权」沿用本项目 README 与项目主页一直使用的团队署名。两处原文不同，这里按各自来源分列，未擅自统一。")
                        .font(.system(size: 11)).foregroundStyle(.secondary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 7) {
                    SectionHead(title: "联系与合作", sub: "邮箱、地址、教师主页照录官网 /contact/ 页；项目链接指向本仓库")
                    KeyRow(k: "邮箱", v: LabInfo.email)
                    KeyRow(k: "通讯地址", v: LabInfo.address)
                    KeyRow(k: "", v: LabInfo.addressEN)
                    HStack(spacing: 14) {
                        LinkPill(title: "✉️ 写邮件", url: "mailto:\(LabInfo.email)")
                        LinkPill(title: "实验室主页", url: LabInfo.labSite)
                        LinkPill(title: "加入与合作", url: LabInfo.contactPage)
                        LinkPill(title: "教师主页", url: LabInfo.facultyPage)
                        LinkPill(title: "GitHub", url: LabInfo.repo)
                        LinkPill(title: "项目主页", url: LabInfo.projectPage)
                    }
                    .padding(.top, 3)
                    Text("官网未提供电话、邮编或微信公众号，因此这里没有列——不推测、不代填。")
                        .font(.system(size: 11)).foregroundStyle(.secondary.opacity(0.85))
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHead(title: "当前状态：还不是「完美」", sub: "已走通的与没验证的，分开写清楚")
                    StatusRow(ok: true, text: "macOS 桌面版已在 Apple M5 Max / 128 GB / macOS 27.0.1 实跑：带宽实测、GGUF 导入、Ollama 注册、真实生成测速、智能体工具调用。")
                    StatusRow(ok: true, text: "在线模型、下载、断点续传、批量队列、实测基线等功能已实现并编译通过；改动均离线复核过数值与排版。")
                    StatusRow(ok: true, text: "11 个页签逐一离屏渲染冒烟通过：无崩溃、无文字截断、无渲染占位块；URL/署名/时间戳有独立命令行断言复核。")
                    StatusRow(ok: false, text: "Windows / Linux 安装包由 CI 产出，从未在真实硬件上打开运行；探测层（DXGI/NVML、sysfs）待真机验证。")
                    StatusRow(ok: false, text: "本机没有 cargo，Rust 核心与 CLI 的一致性测试无法在这里运行；改速度公式会动到它，所以这次没改。")
                    StatusRow(ok: false, text: "概览页用保守系数 0.45，在线模型页用实测校准过的模型；同一模型两页 tok/s 可能差 1.5–2.5 倍，已在概览页标注。")
                    StatusRow(ok: false, text: "应用图标的文件与 bundle 元数据已核验，但本环境取不到 Dock / Finder 的真实渲染，需要你目视确认。")
                    StatusRow(ok: false, text: "在线搜索只给模型名；名字里没有参数量的模型无法估算，界面已明说「不代表跑不动」。所有速度估算误差约 ±30%，以实测为准。")
                }
            }
        }
    }

    /// 直接读 bundle 里的 icns，和 Dock 用的是同一个文件
    var appIcon: some View {
        Group {
            if let p = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
               let img = NSImage(contentsOfFile: p) {
                Image(nsImage: img).resizable().frame(width: 84, height: 84)
            } else {
                Image(systemName: "app.dashed").font(.system(size: 42))
                    .frame(width: 84, height: 84).foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// 一枚可点的链接：走系统默认浏览器 / 邮件客户端
struct LinkPill: View {
    let title: String
    let url: String

    var body: some View {
        Button {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        } label: {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(T.accent.opacity(0.12))
                .foregroundStyle(T.accent)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(T.accent.opacity(0.28), lineWidth: 0.6))
        }
        .buttonStyle(.plain)
        .help(url)
    }
}

/// 已走通 / 未验证 的一行，颜色与符号都不含糊
struct StatusRow: View {
    let ok: Bool
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 11))
                .foregroundStyle(ok ? T.good : T.warn)
                .frame(width: 13)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(ok ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
