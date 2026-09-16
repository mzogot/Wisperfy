import AppKit

// Wisperfy app icon: macOS squircle, graphite glass background, the app's own HUD capsule
// (recording dot + level meter) as the mark. 1024x1024, Apple's 824px icon body.
let canvas: CGFloat = 1024
let body: CGFloat = 824
let inset = (canvas - body) / 2
let radius = body * 0.2237

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: canvas, height: canvas)
let gctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = gctx
let ctx = gctx.cgContext

// Transparent canvas, drop shadow below the squircle.
ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
let bodyRect = CGRect(x: inset, y: inset, width: body, height: body)
let squircle = NSBezierPath(roundedRect: bodyRect, xRadius: radius, yRadius: radius)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
squircle.fill()
ctx.restoreGState()

// Background: deep graphite with a cool top light, like a dark material surface.
ctx.saveGState()
squircle.addClip()
let bg = NSGradient(colors: [
    NSColor(calibratedRed: 0.20, green: 0.21, blue: 0.24, alpha: 1),
    NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.12, alpha: 1)
])!
bg.draw(in: bodyRect, angle: -90)

// Soft red glow behind the dot side: hints at "listening" without shouting.
let glow = NSGradient(colors: [
    NSColor(calibratedRed: 1.0, green: 0.27, blue: 0.23, alpha: 0.28),
    NSColor(calibratedRed: 1.0, green: 0.27, blue: 0.23, alpha: 0.0)
])!
glow.draw(fromCenter: CGPoint(x: 340, y: 520), radius: 0,
          toCenter: CGPoint(x: 340, y: 520), radius: 420, options: [])

// Top highlight rim.
let rim = NSGradient(colors: [NSColor.white.withAlphaComponent(0.14), NSColor.white.withAlphaComponent(0.0)])!
rim.draw(in: bodyRect, angle: 90)
ctx.restoreGState()

// The HUD capsule: frosted, hairline border.
let capW: CGFloat = 600, capH: CGFloat = 200
let capRect = CGRect(x: (canvas - capW) / 2, y: (canvas - capH) / 2, width: capW, height: capH)
let capsule = NSBezierPath(roundedRect: capRect, xRadius: capH / 2, yRadius: capH / 2)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: NSColor.black.withAlphaComponent(0.45).cgColor)
NSColor(calibratedWhite: 0.92, alpha: 0.18).setFill()
capsule.fill()
ctx.restoreGState()

ctx.saveGState()
capsule.addClip()
let capGrad = NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0.08)])!
capGrad.draw(in: capRect, angle: -90)
ctx.restoreGState()
NSColor.white.withAlphaComponent(0.22).setStroke()
capsule.lineWidth = 3
capsule.stroke()

// Recording dot with a soft halo.
let heights: [CGFloat] = [0.35, 0.72, 1.0, 0.58, 0.42]
let barW: CGFloat = 34, gap: CGFloat = 24, maxH: CGFloat = 126
let dotD: CGFloat = 64, dotGap: CGFloat = 64
let barsW = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
let groupW = dotD + dotGap + barsW
let groupX = capRect.midX - groupW / 2
let dotCenter = CGPoint(x: groupX + dotD / 2, y: capRect.midY)
let red = NSColor(calibratedRed: 1.0, green: 0.27, blue: 0.23, alpha: 1)
let halo = NSGradient(colors: [red.withAlphaComponent(0.45), red.withAlphaComponent(0)])!
halo.draw(fromCenter: dotCenter, radius: 0, toCenter: dotCenter, radius: 70, options: [])
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 18, color: red.withAlphaComponent(0.8).cgColor)
red.setFill()
NSBezierPath(ovalIn: CGRect(x: dotCenter.x - 30, y: dotCenter.y - 30, width: 60, height: 60)).fill()
ctx.restoreGState()

// Level meter: five rounded bars, the HUD's own proportions.
var x = groupX + dotD + dotGap
for h in heights {
    let bh = maxH * h
    let r = CGRect(x: x, y: capRect.midY - bh / 2, width: barW, height: bh)
    NSColor.white.withAlphaComponent(0.92).setFill()
    NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2).fill()
    x += barW + gap
}

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "icon_1024.png"))
print("wrote icon_1024.png")
