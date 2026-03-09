import AppKit
import Foundation

enum AppIconFactory {
  static func makeIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let bounds = NSRect(x: 0, y: 0, width: size, height: size)
    let basePath = NSBezierPath(roundedRect: bounds, xRadius: size * 0.22, yRadius: size * 0.22)
    let baseGradient = NSGradient(colors: [
      NSColor(calibratedRed: 0.94, green: 0.55, blue: 0.27, alpha: 1),
      NSColor(calibratedRed: 0.86, green: 0.24, blue: 0.20, alpha: 1),
    ])!
    baseGradient.draw(in: basePath, angle: -90)

    let paperRect = NSRect(x: size * 0.19, y: size * 0.14, width: size * 0.62, height: size * 0.72)
    let paperPath = NSBezierPath(roundedRect: paperRect, xRadius: size * 0.08, yRadius: size * 0.08)
    NSColor(calibratedWhite: 0.99, alpha: 1).setFill()
    paperPath.fill()

    let fold = NSBezierPath()
    fold.move(to: NSPoint(x: paperRect.maxX - size * 0.15, y: paperRect.maxY))
    fold.line(to: NSPoint(x: paperRect.maxX, y: paperRect.maxY - size * 0.15))
    fold.line(to: NSPoint(x: paperRect.maxX, y: paperRect.maxY))
    fold.close()
    NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
    fold.fill()

    let lineColor = NSColor(calibratedRed: 0.82, green: 0.32, blue: 0.22, alpha: 1)
    for index in 0..<4 {
      let y = size * (0.66 - CGFloat(index) * 0.11)
      let line = NSBezierPath(
        roundedRect: NSRect(x: size * 0.29, y: y, width: size * 0.33, height: size * 0.034),
        xRadius: size * 0.017,
        yRadius: size * 0.017
      )
      lineColor.setFill()
      line.fill()
    }

    let spark = NSBezierPath()
    spark.move(to: NSPoint(x: size * 0.69, y: size * 0.42))
    spark.line(to: NSPoint(x: size * 0.74, y: size * 0.52))
    spark.line(to: NSPoint(x: size * 0.84, y: size * 0.57))
    spark.line(to: NSPoint(x: size * 0.74, y: size * 0.62))
    spark.line(to: NSPoint(x: size * 0.69, y: size * 0.72))
    spark.line(to: NSPoint(x: size * 0.64, y: size * 0.62))
    spark.line(to: NSPoint(x: size * 0.54, y: size * 0.57))
    spark.line(to: NSPoint(x: size * 0.64, y: size * 0.52))
    spark.close()
    NSColor(calibratedRed: 1.0, green: 0.86, blue: 0.33, alpha: 1).setFill()
    spark.fill()

    image.unlockFocus()
    image.isTemplate = false
    return image
  }
}

func pngData(for image: NSImage, size: Int) -> Data? {
  guard
    let tiff = image.tiffRepresentation,
    NSBitmapImageRep(data: tiff) != nil
  else { return nil }

  let resized = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
  )

  guard let resized else { return nil }
  resized.size = NSSize(width: size, height: size)

  NSGraphicsContext.saveGraphicsState()
  let context = NSGraphicsContext(bitmapImageRep: resized)
  NSGraphicsContext.current = context
  image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
  context?.flushGraphics()
  NSGraphicsContext.restoreGraphicsState()

  return resized.representation(using: .png, properties: [:])
}

let outputPath = CommandLine.arguments.dropFirst().first ?? ""
guard !outputPath.isEmpty else {
  fputs("usage: swift export-icon.swift <iconset-dir>\n", stderr)
  exit(1)
}

let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

let variants: [(base: Int, scale: Int)] = [
  (16, 1), (16, 2),
  (32, 1), (32, 2),
  (128, 1), (128, 2),
  (256, 1), (256, 2),
  (512, 1), (512, 2),
]

for variant in variants {
  let pixels = variant.base * variant.scale
  let image = AppIconFactory.makeIcon(size: CGFloat(pixels))
  guard let data = pngData(for: image, size: pixels) else {
    fputs("failed to render icon variant \(variant.base)x\(variant.base)@\(variant.scale)x\n", stderr)
    exit(1)
  }

  let suffix = variant.scale == 2 ? "@2x" : ""
  let filename = "icon_\(variant.base)x\(variant.base)\(suffix).png"
  try data.write(to: outputURL.appendingPathComponent(filename), options: .atomic)
}
