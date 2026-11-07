import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

// MindModel 图标生成器
// 设计：圆盘内「机与心」——左半三角晶格（模型/机器），右半同心脑回（心智/信号），
//       中缝一道细光，圆心一枚亮点，整块落在深靛蓝玻璃方块上。
// 小尺寸（≤32px）自动切到简化画法：加粗弧线与描边、放大光点、隐去细网格，避免糊成一团。
//
// 用法：
//   swift IconGen.swift <输出目录>         生成完整 .iconset（16…1024）
//   swift IconGen.swift <输出目录> --png   只生成 1024 预览图

let S: CGFloat = 1024
let inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
let corner: CGFloat = 185

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: a)
}

func makeContext(_ px: Int) -> CGContext {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                      bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setAllowsAntialiasing(true)
    c.interpolationQuality = .high
    c.scaleBy(x: CGFloat(px) / S, y: CGFloat(px) / S)   // 统一在 1024 坐标系绘制
    return c
}

/// 圆角方块路径（Apple 图标约 824×824、圆角 185）
func tilePath() -> CGPath {
    CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)
}

func linear(_ c: CGContext, _ colors: [CGColor], _ locs: [CGFloat], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                       colors: colors as CFArray, locations: locs)!
    c.drawLinearGradient(g, start: from, end: to,
                         options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func radial(_ c: CGContext, _ colors: [CGColor], _ locs: [CGFloat], center: CGPoint, radius: CGFloat) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                       colors: colors as CFArray, locations: locs)!
    c.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
                         options: [.drawsAfterEndLocation])
}

/// 主绘制。simple = 小尺寸简化画法。
func drawMind(_ c: CGContext, simple: Bool) {
    let wMul: CGFloat = simple ? 2.3 : 1.0
    let ctr = CGPoint(x: 512, y: 516)
    let R: CGFloat = simple ? 296 : 284

    // ── 底：深靛蓝玻璃 ──
    c.saveGState()
    c.addPath(tilePath()); c.clip()
    linear(c, [rgb(0x2A1A70), rgb(0x150D3C), rgb(0x06040F)], [0, 0.52, 1],
           from: CGPoint(x: 220, y: 1010), to: CGPoint(x: 880, y: 140))
    radial(c, [rgb(0x7A55FF, 0.34), rgb(0x7A55FF, 0)], [0, 1],
           center: CGPoint(x: 470, y: 620), radius: 600)
    radial(c, [rgb(0x2BD3FF, 0.15), rgb(0x2BD3FF, 0)], [0, 1],
           center: CGPoint(x: 800, y: 330), radius: 420)
    c.restoreGState()

    c.saveGState()
    c.addPath(tilePath()); c.clip()

    let circle = CGMutablePath()
    circle.addEllipse(in: CGRect(x: ctr.x - R, y: ctr.y - R, width: R * 2, height: R * 2))

    // 圆内淡淡压暗，让图形浮起来（小尺寸几乎不压，保对比）
    c.saveGState()
    c.addPath(circle); c.clip()
    radial(c, [rgb(0x1A1048, simple ? 0.18 : 0.55), rgb(0x0B0620, simple ? 0.24 : 0.62)],
           [0, 1], center: ctr, radius: R)
    c.restoreGState()

    // ── 左半：三角晶格 ──
    c.saveGState()
    c.addPath(circle); c.clip()
    let leftClip = CGMutablePath()
    leftClip.addRect(CGRect(x: ctr.x - R - 20, y: ctr.y - R - 20, width: R + 20, height: R * 2 + 40))
    c.addPath(leftClip); c.clip()

    let step: CGFloat = simple ? 88 : 56
    c.setLineWidth(2.0 * wMul)
    c.setStrokeColor(rgb(0x7AD9FF, simple ? 0.55 : 0.40))
    var yy = ctr.y - R
    while yy <= ctr.y + R {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: ctr.x - R, y: yy)); p.addLine(to: CGPoint(x: ctr.x, y: yy))
        c.addPath(p); c.strokePath(); yy += step
    }
    var xx = ctr.x - R
    while xx <= ctr.x {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: xx, y: ctr.y - R)); p.addLine(to: CGPoint(x: xx, y: ctr.y + R))
        c.addPath(p); c.strokePath(); xx += step
    }
    if !simple {
        // 双向斜线 → 三角面；节点小圆点。小尺寸省略，否则会糊。
        c.setLineWidth(1.6)
        c.setStrokeColor(rgb(0xB79BFF, 0.34))
        var o = -R - step
        while o <= R + step {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: ctr.x - R, y: ctr.y + o))
            p.addLine(to: CGPoint(x: ctr.x, y: ctr.y + o - R))
            c.addPath(p); c.strokePath()
            let q = CGMutablePath()
            q.move(to: CGPoint(x: ctr.x - R, y: ctr.y + o))
            q.addLine(to: CGPoint(x: ctr.x, y: ctr.y + o + R))
            c.addPath(q); c.strokePath()
            o += step * 2
        }
        c.setFillColor(rgb(0xD9F4FF, 0.55))
        var ny = ctr.y - R
        while ny <= ctr.y + R {
            var nx = ctr.x - R
            while nx <= ctr.x {
                c.fillEllipse(in: CGRect(x: nx - 2.4, y: ny - 2.4, width: 4.8, height: 4.8))
                nx += step
            }
            ny += step
        }
    }
    c.restoreGState()

    // ── 右半：同心脑回 ──
    c.saveGState()
    c.addPath(circle); c.clip()
    let rightClip = CGMutablePath()
    rightClip.addRect(CGRect(x: ctr.x, y: ctr.y - R - 20, width: R + 20, height: R * 2 + 40))
    c.addPath(rightClip); c.clip()
    c.setLineCap(.round)

    let arcs: [(r: CGFloat, w: CGFloat, col: UInt32, a: CGFloat)] = simple
        ? [(112, 52, 0xC8F6FF, 1.0), (196, 44, 0xC9B4FF, 0.98), (280, 36, 0x9FE8FF, 0.95)]
        : [(104, 30, 0xA9F0FF, 0.95), (162, 27, 0xB79BFF, 0.92),
           (220, 24, 0x8FE6FF, 0.90), (278, 21, 0xC6A9FF, 0.85)]
    for (i, A) in arcs.enumerated() {
        let span: CGFloat = (i >= arcs.count - 2) ? 1.30 : 1.42
        c.saveGState()
        c.setShadow(offset: .zero, blur: 30, color: rgb(A.col, 0.55 * A.a))
        c.setStrokeColor(rgb(A.col, A.a))
        c.setLineWidth(A.w)
        c.addArc(center: ctr, radius: A.r, startAngle: -span, endAngle: span, clockwise: false)
        c.strokePath()
        c.restoreGState()
    }
    c.restoreGState()

    // ── 中缝细光 ──
    c.saveGState()
    c.addPath(circle); c.clip()
    c.setBlendMode(.plusLighter)
    let seamW: CGFloat = simple ? 14 : 18
    let seam = CGMutablePath()
    seam.addRect(CGRect(x: ctr.x - seamW / 2, y: ctr.y - R, width: seamW, height: R * 2))
    c.addPath(seam); c.clip()
    linear(c, [rgb(0xFFFFFF, 0), rgb(0xFFFFFF, simple ? 0.42 : 0.30), rgb(0xFFFFFF, 0)], [0, 0.5, 1],
           from: CGPoint(x: ctr.x, y: ctr.y - R), to: CGPoint(x: ctr.x, y: ctr.y + R))
    c.restoreGState()

    // ── 圆心核 ──
    c.saveGState()
    c.setBlendMode(.plusLighter)
    radial(c, [rgb(0xFFFFFF, simple ? 0.75 : 0.55), rgb(0xBFF1FF, 0.25), rgb(0x6AD8FF, 0)],
           [0, 0.35, 1], center: ctr, radius: simple ? 100 : 74)
    c.restoreGState()
    let dotR: CGFloat = simple ? 19 : 13
    c.setFillColor(rgb(0xFFFFFF, 0.97))
    c.fillEllipse(in: CGRect(x: ctr.x - dotR, y: ctr.y - dotR, width: dotR * 2, height: dotR * 2))

    // ── 圆环描边（左上亮 → 右下暗） ──
    c.saveGState()
    c.addPath(circle.copy(strokingWithWidth: simple ? 14 : 4, lineCap: .round,
                          lineJoin: .round, miterLimit: 10))
    c.clip()
    linear(c, [rgb(0xFFFFFF, 0.62), rgb(0xB6E9FF, 0.30), rgb(0x6A3BE0, 0.10)], [0, 0.5, 1],
           from: CGPoint(x: ctr.x - R * 0.7, y: ctr.y + R), to: CGPoint(x: ctr.x + R, y: ctr.y - R * 0.6))
    c.restoreGState()

    c.restoreGState()

    // ── 玻璃边 ──
    c.saveGState()
    c.addPath(tilePath().copy(strokingWithWidth: simple ? 5 : 3, lineCap: .round,
                              lineJoin: .round, miterLimit: 10))
    c.clip()
    linear(c, [rgb(0xFFFFFF, 0.48), rgb(0xFFFFFF, 0.05)], [0, 1],
           from: CGPoint(x: 512, y: 1000), to: CGPoint(x: 512, y: 200))
    c.restoreGState()
}

func render(px: Int, simple: Bool) -> CGImage {
    let c = makeContext(px)
    drawMind(c, simple: simple)
    return c.makeImage()!
}

func writePNG(_ img: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
        print("无法写出 \(path)"); return
    }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

// MARK: - 输出

let args = CommandLine.arguments
let outDir = args.count > 1 ? args[1] : "./AppIcon.iconset"
let pngOnly = args.contains("--png")

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

if pngOnly {
    writePNG(render(px: 1024, simple: false), "\(outDir)/icon-1024.png")
    writePNG(render(px: 32, simple: true), "\(outDir)/icon-32-small.png")
    print("写出 1024 预览图 + 32px 简化版")
} else {
    let jobs: [(name: String, px: Int, simple: Bool)] = [
        ("icon_16x16",      16,  true),
        ("icon_16x16@2x",   32,  true),
        ("icon_32x32",      32,  true),
        ("icon_32x32@2x",   64,  true),
        ("icon_128x128",    128, false),
        ("icon_128x128@2x", 256, false),
        ("icon_256x256",    256, false),
        ("icon_256x256@2x", 512, false),
        ("icon_512x512",    512, false),
        ("icon_512x512@2x", 1024, false),
    ]
    for j in jobs {
        writePNG(render(px: j.px, simple: j.simple), "\(outDir)/\(j.name).png")
        print("  \(j.name).png  \(j.px)px\(j.simple ? "（简化）" : "")")
    }
    print("完成：\(outDir)")
}
