// EC2Dock 앱 아이콘(1024×1024 PNG)을 그린다.
// 콘셉트: 주황색 "Dock" 위에 쌓인 EC2 서버 유닛 + 터미널 프롬프트.
// 사용: swift scripts/make-icon.swift <출력 PNG 경로>
// scripts/make-icon.sh가 이 PNG로 AppIcon.icns를 만든다.
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let canvas: CGFloat = 1024

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func withShadow(_ color: NSColor, blur: CGFloat, offset: NSSize = .zero, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = offset
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

// 레티나 배율과 관계없이 정확히 1024px로 그리기 위해 비트맵에 직접 그린다.
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSGraphicsContext.current?.imageInterpolation = .high

// MARK: 바탕 (macOS 아이콘 격자: 1024 캔버스 안 824 크기)
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)

withShadow(rgb(0x000000, 0.35), blur: 28, offset: NSSize(width: 0, height: -14)) {
    rgb(0x0E1528).setFill()
    bodyPath.fill()
}
NSGradient(colors: [rgb(0x2C3D6B), rgb(0x16213F), rgb(0x0A1020)], atLocations: [0, 0.55, 1],
           colorSpace: .sRGB)!.draw(in: bodyPath, angle: -90)

NSGraphicsContext.saveGraphicsState()
bodyPath.addClip()
// Dock에서 번지는 주황 빛
NSGradient(colors: [rgb(0xFF8A1F, 0.34), rgb(0xFF8A1F, 0.08), rgb(0xFF8A1F, 0.0)], atLocations: [0, 0.55, 1],
           colorSpace: .sRGB)!
    .draw(fromCenter: NSPoint(x: 512, y: 286), radius: 0, toCenter: NSPoint(x: 512, y: 286), radius: 340, options: [])
// 위쪽 은은한 광택
NSGradient(colors: [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0.0)], atLocations: [0, 1], colorSpace: .sRGB)!
    .draw(in: NSRect(x: 100, y: 600, width: 824, height: 324), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// 테두리 하이라이트
rgb(0xFFFFFF, 0.08).setStroke()
let rim = NSBezierPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), xRadius: 185, yRadius: 185)
rim.lineWidth = 3
rim.stroke()

// MARK: Dock 바
let dock = NSRect(x: 214, y: 262, width: 596, height: 48)
let dockPath = NSBezierPath(roundedRect: dock, xRadius: 24, yRadius: 24)
withShadow(rgb(0xFF7A00, 0.75), blur: 46) {
    rgb(0xFF8A1F).setFill()
    dockPath.fill()
}
NSGradient(colors: [rgb(0xFFC15A), rgb(0xFF8A1F), rgb(0xF26B00)], atLocations: [0, 0.5, 1],
           colorSpace: .sRGB)!.draw(in: dockPath, angle: -90)
rgb(0xFFFFFF, 0.55).setFill()
NSBezierPath(roundedRect: NSRect(x: dock.minX + 30, y: dock.maxY - 12, width: dock.width - 60, height: 5),
             xRadius: 2.5, yRadius: 2.5).fill()

// MARK: 서버 유닛 3대
struct Unit {
    let y: CGFloat
    let led: UInt32
    let showsPrompt: Bool
}
let unitX: CGFloat = 262
let unitWidth: CGFloat = 500
let unitHeight: CGFloat = 116
let units = [
    Unit(y: 344, led: 0x30D158, showsPrompt: false),
    Unit(y: 484, led: 0xFFB020, showsPrompt: false),
    Unit(y: 624, led: 0x30D158, showsPrompt: true),
]

for unit in units {
    let rect = NSRect(x: unitX, y: unit.y, width: unitWidth, height: unitHeight)
    let path = NSBezierPath(roundedRect: rect, xRadius: 30, yRadius: 30)

    withShadow(rgb(0x000000, 0.5), blur: 22, offset: NSSize(width: 0, height: -10)) {
        rgb(0xE4E9F2).setFill()
        path.fill()
    }
    NSGradient(colors: [rgb(0xFFFFFF), rgb(0xE7ECF4), rgb(0xC6CFDF)], atLocations: [0, 0.45, 1],
               colorSpace: .sRGB)!.draw(in: path, angle: -90)
    // 윗면 반사광
    rgb(0xFFFFFF, 0.9).setFill()
    NSBezierPath(roundedRect: NSRect(x: rect.minX + 28, y: rect.maxY - 9, width: rect.width - 56, height: 4),
                 xRadius: 2, yRadius: 2).fill()

    // 상태 LED
    let ledCenter = NSPoint(x: rect.minX + 58, y: rect.midY)
    let ledRect = NSRect(x: ledCenter.x - 15, y: ledCenter.y - 15, width: 30, height: 30)
    withShadow(rgb(unit.led, 0.95), blur: 18) {
        rgb(unit.led).setFill()
        NSBezierPath(ovalIn: ledRect).fill()
    }
    rgb(0xFFFFFF, 0.65).setFill()
    NSBezierPath(ovalIn: NSRect(x: ledCenter.x - 7, y: ledCenter.y + 2, width: 9, height: 7)).fill()

    if unit.showsPrompt {
        // 터미널 프롬프트 ">_"
        let prompt = NSAttributedString(string: ">_", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 74, weight: .heavy),
            .foregroundColor: rgb(0x1B2645),
        ])
        let size = prompt.size()
        prompt.draw(at: NSPoint(x: rect.minX + 100, y: rect.midY - size.height / 2 + 2))
    }

    // 통풍 슬롯
    for index in 0..<4 {
        let slot = NSRect(x: rect.maxX - 64 - CGFloat(index) * 30, y: rect.midY - 28, width: 12, height: 56)
        rgb(0x8E9AB2).setFill()
        NSBezierPath(roundedRect: slot, xRadius: 6, yRadius: 6).fill()
        rgb(0xFFFFFF, 0.7).setFill()
        NSBezierPath(roundedRect: NSRect(x: slot.minX + 2, y: slot.minY - 3, width: 8, height: 3),
                     xRadius: 1.5, yRadius: 1.5).fill()
    }
}

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("PNG를 만들 수 없습니다.")
}
try png.write(to: URL(fileURLWithPath: output))
print("아이콘 생성: \(output)")
