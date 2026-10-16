// EC2Dock 앱 아이콘(1024×1024 PNG)을 그린다.
// 사용: swift scripts/make-icon.swift <출력 PNG 경로>
// scripts/make-icon.sh가 이 PNG로 AppIcon.icns를 만든다.
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))

image.lockFocus()
// macOS 아이콘 격자: 1024 캔버스 안에 824 크기의 둥근 사각형
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let background = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [
    NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.24, alpha: 1),
    NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.11, alpha: 1),
])!.draw(in: background, angle: -90)

// 서버 랙 기호
let configuration = NSImage.SymbolConfiguration(pointSize: 420, weight: .regular)
    .applying(.init(paletteColors: [NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.1, alpha: 1)]))
if let symbol = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)?
    .withSymbolConfiguration(configuration) {
    let symbolSize = symbol.size
    symbol.draw(in: NSRect(x: (size - symbolSize.width) / 2, y: (size - symbolSize.height) / 2 + 40,
                           width: symbolSize.width, height: symbolSize.height))
}

// 터미널 프롬프트 표시
let prompt = NSAttributedString(string: ">_", attributes: [
    .font: NSFont.monospacedSystemFont(ofSize: 150, weight: .bold),
    .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 1),
])
prompt.draw(at: NSPoint(x: rect.minX + 70, y: rect.minY + 40))
image.unlockFocus()

guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("PNG를 만들 수 없습니다.")
}
try png.write(to: URL(fileURLWithPath: output))
print("아이콘 생성: \(output)")
