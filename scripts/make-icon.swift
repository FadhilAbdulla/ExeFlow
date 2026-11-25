// usage: swift make-icon.swift <output.iconset>
// Original artwork: a program window flowing into a laptop. No third-party logos.
import AppKit
let out = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
func rgb(_ h: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(h >> 16 & 255) / 255, green: CGFloat(h >> 8 & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}
func rounded(_ r: NSRect, _ k: CGFloat) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: k, yRadius: k) }

func draw(_ s: CGFloat) {
    let u = s / 1024
    func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x*u, y: y*u, width: w*u, height: h*u) }
    let small = s <= 32 // drop fine detail that would turn to mush

    let tile = rounded(R(100, 100, 824, 824), 186*u)
    NSGradient(colors: [rgb(0x3A2BD8), rgb(0x6A3DF0), rgb(0x18B7E8)])!.draw(in: tile, angle: 60)
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    NSGradient(starting: rgb(0xFFFFFF, 0.22), ending: rgb(0xFFFFFF, 0))!.draw(in: R(100, 512, 824, 412), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    func line(_ width: CGFloat) -> NSBezierPath {
        let p = NSBezierPath(); p.lineWidth = width*u; p.lineCapStyle = .round; p.lineJoinStyle = .round; return p
    }
    func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x*u, y: y*u) }

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = rgb(0x0B0838, 0.35); shadow.shadowOffset = NSSize(width: 0, height: -12*u); shadow.shadowBlurRadius = 28*u
    if !small { shadow.set() }

    // two arcs: program -> Mac, and back, reading as one flow
    func arc(_ from: NSPoint, _ c1: NSPoint, _ c2: NSPoint, _ to: NSPoint, _ a: NSPoint, _ b: NSPoint, _ w: CGFloat) {
        let p = line(w); p.move(to: from); p.curve(to: to, controlPoint1: c1, controlPoint2: c2); p.stroke()
        let h = line(w); h.move(to: a); h.line(to: to); h.line(to: b); h.stroke()
    }
    rgb(0xFFFFFF).set()
    if small { // only a bold arrow survives at tiny sizes
        arc(P(260, 350), P(260, 600), P(420, 640), P(740, 640), P(590, 790), P(590, 490), 120)
        NSGraphicsContext.restoreGraphicsState()
        return
    }
    arc(P(560, 690), P(650, 690), P(700, 640), P(700, 548), P(638, 606), P(762, 606), 48)
    rgb(0xFFFFFF, 0.6).set()
    arc(P(464, 310), P(374, 310), P(324, 360), P(324, 452), P(262, 394), P(386, 394), 48)
    rgb(0xFFFFFF).set()

    // program window
    rounded(R(196, 548, 290, 250), 40*u).fill()
    // laptop
    rounded(R(572, 280, 256, 190), 30*u).fill()
    rounded(R(530, 222, 340, 44), 22*u).fill()
    NSGraphicsContext.restoreGraphicsState()

    rgb(0x4A32E0).setFill()
    rounded(R(228, 580, 226, 122), 18*u).fill()
    for (i, c) in [0x3A2BD8, 0x8A5BFF, 0x18B7E8].enumerated() {
        rgb(c).setFill()
        NSBezierPath(ovalIn: R(234 + CGFloat(i)*44, 736, 28, 28)).fill()
    }
    rgb(0x18A4DC).setFill()
    rounded(R(602, 310, 196, 130), 14*u).fill()
}

for (pt, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let px = pt * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGFloat(px))
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"))
}
