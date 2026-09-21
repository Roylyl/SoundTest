import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let icon = root.appendingPathComponent("SoundTest/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: icon, withIntermediateDirectories: true)
let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 4096,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(red: 0.114, green: 0.318, blue: 0.573, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
for (text, size, y) in [("Sound", 215.0, 530.0), ("test", 225.0, 300.0)] {
    let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)!
    let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    context.textPosition = CGPoint(x: (1024 - width) / 2, y: y)
    CTLineDraw(line, context)
}
let destination = CGImageDestinationCreateWithURL(icon.appendingPathComponent("AppIcon.png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
precondition(CGImageDestinationFinalize(destination))
try "{\"images\":[{\"filename\":\"AppIcon.png\",\"idiom\":\"universal\",\"platform\":\"ios\",\"size\":\"1024x1024\"}],\"info\":{\"author\":\"xcode\",\"version\":1}}".write(to: icon.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
try "{\"info\":{\"author\":\"xcode\",\"version\":1}}".write(to: root.appendingPathComponent("SoundTest/Assets.xcassets/Contents.json"), atomically: true, encoding: .utf8)
