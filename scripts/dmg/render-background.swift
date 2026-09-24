import AppKit

struct Layout: Decodable {
  let width: Int
  let height: Int
  let iconSize: Int
  let appIconCenter: [Int]
  let applicationsIconCenter: [Int]
}

// Finder draws the actual app and Applications icons over this artwork.
// Both representations describe the same logical size for Retina displays.
func render(_ layout: Layout, scale: Int, to output: URL) throws {
  let width = CGFloat(layout.width)
  let height = CGFloat(layout.height)
  guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: layout.width * scale, pixelsHigh: layout.height * scale,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
  ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    throw CocoaError(.fileWriteUnknown)
  }
  NSGraphicsContext.saveGraphicsState()
  defer { NSGraphicsContext.restoreGraphicsState() }
  NSGraphicsContext.current = context
  context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

  let canvas = NSRect(x: 0, y: 0, width: width, height: height)
  NSColor(srgbRed: 0.975, green: 0.975, blue: 0.969, alpha: 1).setFill()
  canvas.fill()
  let ink = NSColor(srgbRed: 0.13, green: 0.14, blue: 0.15, alpha: 1)
  let secondary = NSColor(srgbRed: 0.38, green: 0.39, blue: 0.41, alpha: 1)

  func text(_ string: String, top: CGFloat, size: CGFloat,
            weight: NSFont.Weight = .regular, color: NSColor) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let lineHeight = size * 1.5
    (string as NSString).draw(
      in: NSRect(x: 32, y: height - top - lineHeight, width: width - 64, height: lineHeight),
      withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                       .foregroundColor: color, .paragraphStyle: paragraph])
  }

  text("Install AeriVoice", top: 49, size: 28, weight: .semibold, color: ink)
  text("Drag AeriVoice into Applications.", top: 96, size: 15, color: secondary)

  // A restrained inset gives the real icons a shared, clearly defined install area.
  let panel = NSBezierPath(roundedRect: NSRect(x: 52, y: height - 316, width: width - 104,
                                              height: 168), xRadius: 22, yRadius: 22)
  NSColor.white.withAlphaComponent(0.75).setFill()
  panel.fill()
  NSColor(white: 0, alpha: 0.045).setStroke()
  panel.lineWidth = 1
  panel.stroke()

  let centerX = CGFloat(layout.appIconCenter[0] + layout.applicationsIconCenter[0]) / 2
  let centerY = height - CGFloat(layout.appIconCenter[1])
  let arrow = NSBezierPath()
  arrow.move(to: NSPoint(x: centerX - 20, y: centerY))
  arrow.line(to: NSPoint(x: centerX + 20, y: centerY))
  arrow.move(to: NSPoint(x: centerX + 12, y: centerY + 8))
  arrow.line(to: NSPoint(x: centerX + 20, y: centerY))
  arrow.line(to: NSPoint(x: centerX + 12, y: centerY - 8))
  arrow.lineWidth = 2
  arrow.lineCapStyle = .round
  arrow.lineJoinStyle = .round
  NSColor(white: 0.55, alpha: 1).setStroke()
  arrow.stroke()

  text("Open AeriVoice from Applications to get started.", top: 349, size: 13, color: secondary)
  bitmap.size = NSSize(width: width, height: height)
  guard let data = bitmap.representation(using: .png, properties: [:]) else {
    throw CocoaError(.fileWriteUnknown)
  }
  try data.write(to: output, options: .atomic)
}

guard CommandLine.arguments.count == 3 else {
  fputs("Usage: render-background.swift layout.json output-directory\n", stderr)
  exit(64)
}
let layout = try JSONDecoder().decode(
  Layout.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
try render(layout, scale: 1, to: directory.appendingPathComponent("background.png"))
try render(layout, scale: 2, to: directory.appendingPathComponent("background@2x.png"))
