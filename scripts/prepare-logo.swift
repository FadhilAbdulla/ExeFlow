// usage: swift prepare-logo.swift <artwork> <x> <y> <w> <h> <output.png>
// Centres the symbol (pixel box, top-left origin, light background) on a white rounded tile for the app icon.
import AppKit
let a = CommandLine.arguments, n = a[2...5].map { CGFloat(Double($0)!) }
let src = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: a[1])))!
let crop = src.cgImage!.cropping(to: CGRect(x: n[0], y: n[1], width: n[2], height: n[3]))!
// Lift the near-white paper texture to pure white so no crop edge shows.
let cw = crop.width, ch = crop.height
var px = [UInt8](repeating: 255, count: cw * ch * 4)
let ctx = CGContext(data: &px, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: cw * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.draw(crop, in: CGRect(x: 0, y: 0, width: cw, height: ch))
for i in stride(from: 0, to: px.count, by: 4) {
    // fade to white near the crop's border, where only the soft shadow remains
    let x = i / 4 % cw, y = i / 4 / cw
    let edge = min(1, Double(min(x, y, cw - 1 - x, ch - 1 - y)) / 45)
    for c in 0..<3 {
        let v = min(255, Double(px[i + c]) * 255 / 249)
        px[i + c] = UInt8(255 - (255 - v) * edge)
    }
}
let clean = ctx.makeImage()!
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let g = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = g
g.imageInterpolation = .high
let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 186, yRadius: 186)
NSColor.white.setFill()
tile.fill()
tile.addClip()
g.cgContext.setBlendMode(.multiply) // the artwork's near-white background disappears into the tile
let w: CGFloat = 800, h = w * n[3] / n[2]
g.cgContext.draw(clean, in: NSRect(x: 512 - w / 2, y: 512 - h / 2, width: w, height: h))
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[6]))
