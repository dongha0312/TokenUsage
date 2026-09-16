#!/usr/bin/env swift
//
// 앱 아이콘 생성기.
//
//   swift Xcode/make-icon.swift
//
// 이미지 파일을 저장소에 커밋하는 대신 스크립트를 둔다. 디자인을 고치려면 여기만 고치면 되고,
// 각 크기를 축소가 아니라 직접 그려서 16pt 에서도 막대가 뭉개지지 않는다.
//
// 모티프는 패널에 있는 사용량 막대 그대로다. 세 줄은 세 서비스를, 채움 정도는 사용량을 뜻한다.
// 맨 아래만 경고색인 건 "한도에 가까운 하나를 메뉴바에 띄운다"는 앱의 동작을 그대로 보여준다.

import AppKit

// iconutil 이 요구하는 (파일 이름, 실제 픽셀) 쌍. 규칙을 유추하면 틀린다 —
// 예를 들어 icon_32x32@2x 는 64px 이고, 64x64 라는 이름은 규격에 없다.
let outputs: [(name: String, pixels: Int)] = [
    ("icon_16x16",      16), ("icon_16x16@2x",    32),
    ("icon_32x32",      32), ("icon_32x32@2x",    64),
    ("icon_128x128",   128), ("icon_128x128@2x", 256),
    ("icon_256x256",   256), ("icon_256x256@2x", 512),
    ("icon_512x512",   512), ("icon_512x512@2x", 1024),
]
let outDir = "Xcode/AppIcon.iconset"

/// 채움 비율. 위에서 아래로 갈수록 차오른다.
let bars: [(fill: CGFloat, warning: Bool)] = [
    (0.32, false),
    (0.58, false),
    (0.86, true),
]

func draw(size: Int) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // macOS 아이콘 관례: 캔버스를 꽉 채우지 않고 여백을 둔다.
    let inset = s * 0.094
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.2237          // 스퀘어클 근사

    let plate = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
                       transform: nil)
    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()

    // 바탕: 위에서 아래로 살짝 밝아지는 슬레이트
    let space = CGColorSpaceCreateDeviceRGB()
    let top = CGColor(colorSpace: space, components: [0.153, 0.180, 0.227, 1])!
    let bottom = CGColor(colorSpace: space, components: [0.086, 0.102, 0.133, 1])!
    if let gradient = CGGradient(colorsSpace: space,
                                 colors: [top, bottom] as CFArray,
                                 locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: rect.midX, y: rect.maxY),
                               end: CGPoint(x: rect.midX, y: rect.minY),
                               options: [])
    }

    // 막대
    let barHeight = rect.height * 0.118
    let gap = rect.height * 0.105
    let sideInset = rect.width * 0.155
    let trackWidth = rect.width - sideInset * 2
    let block = barHeight * CGFloat(bars.count) + gap * CGFloat(bars.count - 1)
    var y = rect.midY + block / 2 - barHeight

    for bar in bars {
        let track = CGRect(x: rect.minX + sideInset, y: y, width: trackWidth, height: barHeight)
        let r = barHeight / 2

        ctx.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 0.16])!)
        ctx.addPath(CGPath(roundedRect: track, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.fillPath()

        // 0% 여도 존재가 보이도록 최소 폭을 준다. 패널의 막대와 같은 규칙이다.
        let filled = CGRect(x: track.minX, y: track.minY,
                            width: max(barHeight, trackWidth * bar.fill), height: barHeight)
        let color = bar.warning
            ? CGColor(colorSpace: space, components: [1.0, 0.584, 0.196, 1])!   // 경고
            : CGColor(colorSpace: space, components: [0.290, 0.639, 1.0, 1])!   // 평상
        ctx.setFillColor(color)
        ctx.addPath(CGPath(roundedRect: filled, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.fillPath()

        y -= barHeight + gap
    }

    ctx.restoreGState()

    // 가장자리 하이라이트. 어두운 배경 위에서 판이 떠 보이게 한다.
    ctx.addPath(plate)
    ctx.setStrokeColor(CGColor(colorSpace: space, components: [1, 1, 1, 0.10])!)
    ctx.setLineWidth(max(1, s * 0.0035))
    ctx.strokePath()

    return image
}

func png(_ image: NSImage, size: Int) -> Data? {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    rep.size = NSSize(width: size, height: size)
    return rep.representation(using: .png, properties: [:])
}

try? FileManager.default.removeItem(atPath: outDir)
try! FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// 같은 픽셀 크기를 여러 이름이 공유하므로 한 번만 그려서 재사용한다.
var rendered: [Int: Data] = [:]
for output in outputs {
    if rendered[output.pixels] == nil {
        rendered[output.pixels] = png(draw(size: output.pixels), size: output.pixels)
    }
    guard let data = rendered[output.pixels] else { continue }
    try? data.write(to: URL(fileURLWithPath: "\(outDir)/\(output.name).png"))
}
print("아이콘 \(outputs.count)개 생성: \(outDir)")
