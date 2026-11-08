import AppKit

// Usage: swift scripts/GenerateIcon.swift /path/to/output
// Draws the ten macOS icon PNGs; Contents.json remains in the asset catalog.
// The 256x256 image is also the source for Resources/AppIcon.png used by the READMEs.
// This is a manual asset-authoring tool, not part of the app build.
guard CommandLine.arguments.count == 2 else {
  FileHandle.standardError.write(Data("Usage: swift scripts/GenerateIcon.swift <output-directory>\n".utf8))
  exit(64)
}
let folder = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
  NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
}
func rounded(_ rect: NSRect, _ radius: CGFloat, _ fill: NSColor) {
  fill.setFill()
  NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}
for (name, size) in [
  ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
  ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
  ("icon_512x512", 512), ("icon_512x512@2x", 1024),
] {
  let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
  let logicalSize = Int(name.split(separator: "_")[1].split(separator: "x")[0])!
  let compact = logicalSize <= 32
  let transform = NSAffineTransform()
  transform.scale(by: CGFloat(size) / (compact ? 16 : 1024))
  transform.concat()
  let bg = color(13 / 255, 13 / 255, 14 / 255)
  let surface = color(21 / 255, 21 / 255, 22 / 255)
  let line = color(0.29, 0.29, 0.28)
  let primary = color(236 / 255, 236 / 255, 232 / 255)
  let muted = color(0.49, 0.49, 0.47)
  let accent = color(200 / 255, 217 / 255, 165 / 255)
  if compact {
    // Small-size optical variant, drawn in point space rather than shrinking the master.
    // Fill the available canvas: avoid multiplying the legacy inset by system icon framing.
    rounded(NSRect(x: 0, y: 0, width: 16, height: 16), 2.5, bg)
    func lineAt(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ tint: NSColor) {
      rounded(NSRect(x: x, y: y, width: w, height: h), 0, tint)
    }
    lineAt(2, 13, 5, 1, primary)
    lineAt(13, 13, 1, 1, accent)
    lineAt(2, 4, 12, 7, surface)
    lineAt(10, 4, 0.5, 7, line)
    let glyph = NSBezierPath()
    glyph.move(to: NSPoint(x: 3, y: 9))
    glyph.line(to: NSPoint(x: 5, y: 7.5))
    glyph.line(to: NSPoint(x: 3, y: 6))
    glyph.lineWidth = 1.25
    primary.setStroke()
    glyph.stroke()
    lineAt(6, 5.5, 2.5, 1, primary)
    lineAt(11, 9, 2, 1, muted)
    lineAt(11, 6, 2, 1, accent)
    lineAt(2, 2, 6, 0.75, muted)
    lineAt(11, 2, 3, 0.75, muted)
  } else {
    rounded(NSRect(x: 72, y: 72, width: 880, height: 880), 190, bg)
    let edge = NSBezierPath(
      roundedRect: NSRect(x: 74, y: 74, width: 876, height: 876), xRadius: 188, yRadius: 188)
    line.setStroke()
    edge.lineWidth = 4
    edge.stroke()
    func segment(
      _ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ width: CGFloat, _ tint: NSColor
    ) {
      let p = NSBezierPath()
      p.move(to: NSPoint(x: x1, y: y1))
      p.line(to: NSPoint(x: x2, y: y2))
      p.lineWidth = width
      tint.setStroke()
      p.stroke()
    }
    // Editorial masthead, restrained accent; no document-shaped light surface.
    rounded(NSRect(x: 200, y: 787, width: 185, height: 24), 0, primary)
    rounded(NSRect(x: 411, y: 791, width: 157, height: 16), 0, muted)
    rounded(NSRect(x: 794, y: 787, width: 28, height: 28), 0, accent)
    // One large panel and two small panels echo the report overview.
    rounded(NSRect(x: 196, y: 414, width: 632, height: 310), 0, surface)
    segment(196, 724, 828, 724, 5, line)
    segment(196, 414, 828, 414, 5, line)
    segment(196, 414, 196, 724, 5, line)
    segment(828, 414, 828, 724, 5, line)
    segment(588, 414, 588, 724, 5, line)
    segment(588, 569, 828, 569, 5, line)
    // A strong terminal glyph gives the main panel a readable small-size identity.
    let prompt = NSBezierPath()
    prompt.move(to: NSPoint(x: 276, y: 637))
    prompt.line(to: NSPoint(x: 354, y: 568))
    prompt.line(to: NSPoint(x: 276, y: 499))
    prompt.lineWidth = 27
    prompt.lineJoinStyle = .miter
    primary.setStroke()
    prompt.stroke()
    rounded(NSRect(x: 389, y: 487, width: 107, height: 26), 0, primary)
    rounded(NSRect(x: 637, y: 648, width: 87, height: 12), 0, muted)
    rounded(NSRect(x: 637, y: 601, width: 140, height: 25), 0, primary)
    rounded(NSRect(x: 637, y: 501, width: 78, height: 12), 0, muted)
    rounded(NSRect(x: 637, y: 455, width: 101, height: 25), 0, accent)
    // Compact rows and hairline separators echo the package table.
    for y: CGFloat in [339, 256] {
      rounded(NSRect(x: 200, y: y, width: 215, height: 19), 0, muted)
      rounded(NSRect(x: 650, y: y, width: 174, height: 19), 0, muted)
      segment(196, y - 27, 828, y - 27, 4, line)
    }
  }
  NSGraphicsContext.restoreGraphicsState()
  try bitmap.representation(using: .png, properties: [:])!.write(
    to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
}
