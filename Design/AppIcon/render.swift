// Renders the app icon. Shapes are rasterised with CoreGraphics; everything
// else — gradients, glass, shading, shadows — is composited by hand in a float
// buffer so the material is under our control rather than a filter's.
//
//   swiftc -O render.swift -o render && ./render <output-dir>

import AppKit
import Foundation

// MARK: - Canvas

let SCALE = 2  // supersample, then halve down to 1024 and below
let W = 1024 * SCALE
let CARD_INSET = 100.0
let SIZES = [1024, 512, 256, 128, 64, 32, 16]

func s(_ v: Double) -> Double { v * Double(SCALE) }

/// Premultiplied float RGBA.
struct Buf {
    var r: [Float]
    var g: [Float]
    var b: [Float]
    var a: [Float]
    init() {
        let n = W * W
        r = [Float](repeating: 0, count: n)
        g = r; b = r; a = r
    }
}

// MARK: - Paths

/// A rounded rectangle whose corners follow a degree-n superellipse — Apple's
/// continuous corner, which a degree-5 superellipse matches to within a pixel.
/// With r = half the side this degenerates to the full squircle of the icon grid.
func continuousRoundedRect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double,
                           _ r: Double, _ n: Double = 5.0, steps: Int = 96) -> CGPath {
    let p = CGMutablePath()
    let rx = min(r, (x1 - x0) / 2), ry = min(r, (y1 - y0) / 2)
    // Clockwise on screen: top edge left→right, right edge down, and so on.
    // Each quarter is walked in whichever direction keeps that winding, since
    // a wrong-way quarter would zig-zag between the straight edges.
    let corners = [
        (x1 - rx, y0 + ry,  1.0, -1.0, true),   // top right, entered from the top
        (x1 - rx, y1 - ry,  1.0,  1.0, false),  // bottom right
        (x0 + rx, y1 - ry, -1.0,  1.0, true),   // bottom left
        (x0 + rx, y0 + ry, -1.0, -1.0, false),  // top left
    ]
    var first = true
    for (cx, cy, sx, sy, reversed) in corners {
        for i in 0...steps {
            let f = Double(i) / Double(steps)
            let t = (reversed ? 1 - f : f) * .pi / 2
            let dx = pow(cos(t), 2.0 / n) * rx * sx
            let dy = pow(sin(t), 2.0 / n) * ry * sy
            let pt = CGPoint(x: cx + dx, y: cy + dy)
            if first { p.move(to: pt); first = false } else { p.addLine(to: pt) }
        }
    }
    p.closeSubpath()
    return p
}

/// A speech bubble: a continuous rounded body, optionally with a tail. The tail
/// is held as fractions of the body box so every bubble in the stack carries the
/// same one at its own scale. `tail` is 0 for none, 1 for bottom left, -1 for
/// bottom right.
func bubblePath(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double,
                _ r: Double, n: Double = 5, tail: Int = 0) -> CGPath {
    let p = CGMutablePath()
    p.addPath(continuousRoundedRect(s(x0), s(y0), s(x1), s(y1), s(r), n))
    guard tail != 0 else { return p }

    let w = x1 - x0, h = y1 - y0
    func pt(_ fx: Double, _ fy: Double) -> CGPoint {
        let mx = tail > 0 ? fx : 1 - fx
        return CGPoint(x: s(x0 + mx * w), y: s(y0 + fy * h))
    }

    let t = CGMutablePath()
    t.move(to: pt(0.2778, 0.9109))
    t.addLine(to: pt(0.5000, 0.9109))
    t.addCurve(to: pt(0.2674, 1.3911),
               control1: pt(0.4549, 1.1386), control2: pt(0.3646, 1.3020))
    t.addCurve(to: pt(0.2292, 1.3416),
               control1: pt(0.2361, 1.4183), control2: pt(0.2083, 1.3812))
    t.addCurve(to: pt(0.2778, 0.9109),
               control1: pt(0.2639, 1.2030), control2: pt(0.2778, 1.0644))
    t.closeSubpath()
    p.addPath(t)
    return p
}

// MARK: - Rasterising

/// Antialiased coverage mask of a path, 0…1 per pixel.
func mask(_ path: CGPath, stroke: Double? = nil) -> [Float] {
    var bytes = [UInt8](repeating: 0, count: W * W)
    bytes.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress, width: W, height: W,
                            bitsPerComponent: 8, bytesPerRow: W,
                            space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        // flip so y grows downward, matching the coordinates above
        ctx.translateBy(x: 0, y: CGFloat(W))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setShouldAntialias(true)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.setStrokeColor(gray: 1, alpha: 1)
        ctx.addPath(path)
        if let lw = stroke {
            ctx.setLineWidth(CGFloat(lw))
            ctx.strokePath()
        } else {
            ctx.fillPath()
        }
    }
    return bytes.map { Float($0) / 255 }
}

// MARK: - Blur

/// Three box passes ≈ a Gaussian, separable, in place.
func blur(_ src: [Float], radius: Int) -> [Float] {
    guard radius > 0 else { return src }
    var a = src, b = [Float](repeating: 0, count: W * W)
    for _ in 0..<3 {
        boxH(a, &b, radius); boxV(b, &a, radius)
    }
    return a
}

func boxH(_ src: [Float], _ dst: inout [Float], _ r: Int) {
    let n = 2 * r + 1
    for y in 0..<W {
        let row = y * W
        var sum: Float = src[row] * Float(r + 1)
        for x in 1...r { sum += src[row + min(x, W - 1)] }
        for x in 0..<W {
            dst[row + x] = sum / Float(n)
            sum += src[row + min(x + r + 1, W - 1)] - src[row + max(x - r, 0)]
        }
    }
}

func boxV(_ src: [Float], _ dst: inout [Float], _ r: Int) {
    let n = 2 * r + 1
    for x in 0..<W {
        var sum: Float = src[x] * Float(r + 1)
        for y in 1...r { sum += src[min(y, W - 1) * W + x] }
        for y in 0..<W {
            dst[y * W + x] = sum / Float(n)
            sum += src[min(y + r + 1, W - 1) * W + x] - src[max(y - r, 0) * W + x]
        }
    }
}

func offsetY(_ src: [Float], _ dy: Int) -> [Float] {
    var out = [Float](repeating: 0, count: W * W)
    for y in 0..<W {
        let from = y - dy
        guard from >= 0 && from < W else { continue }
        for x in 0..<W { out[y * W + x] = src[from * W + x] }
    }
    return out
}

// MARK: - Distance field

/// Exact squared Euclidean distance transform (Felzenszwalb & Huttenlocher),
/// measuring how far inside the mask each pixel is.
func insideDistance(_ m: [Float]) -> [Float] {
    let inf: Float = 1e20
    var f = [Float](repeating: 0, count: W * W)
    for i in 0..<W * W { f[i] = m[i] > 0.5 ? inf : 0 }

    var d = [Float](repeating: 0, count: W * W)
    var v = [Int](repeating: 0, count: W)
    var z = [Float](repeating: 0, count: W + 1)

    func transform(_ src: inout [Float], stride: Int, count: Int, offset: Int) {
        var k = 0
        v[0] = 0; z[0] = -inf; z[1] = inf
        for q in 1..<count {
            var s: Float = 0
            while true {
                let p = v[k]
                s = ((src[offset + q * stride] + Float(q * q))
                     - (src[offset + p * stride] + Float(p * p))) / Float(2 * q - 2 * p)
                if s <= z[k] { k -= 1 } else { break }
            }
            k += 1
            v[k] = q; z[k] = s; z[k + 1] = inf
        }
        k = 0
        var row = [Float](repeating: 0, count: count)
        for q in 0..<count {
            while z[k + 1] < Float(q) { k += 1 }
            let p = v[k]
            row[q] = Float((q - p) * (q - p)) + src[offset + p * stride]
        }
        for q in 0..<count { src[offset + q * stride] = row[q] }
    }

    for y in 0..<W { transform(&f, stride: 1, count: W, offset: y * W) }
    for x in 0..<W { transform(&f, stride: W, count: W, offset: x) }
    for i in 0..<W * W { d[i] = sqrt(f[i]) }
    return d
}

// MARK: - Compositing

func over(_ dst: inout Buf, r: [Float], g: [Float], b: [Float], a: [Float]) {
    for i in 0..<W * W {
        let ia = 1 - a[i]
        dst.r[i] = r[i] + dst.r[i] * ia
        dst.g[i] = g[i] + dst.g[i] * ia
        dst.b[i] = b[i] + dst.b[i] * ia
        dst.a[i] = a[i] + dst.a[i] * ia
    }
}

/// Flat colour through a coverage mask.
func fill(_ dst: inout Buf, _ m: [Float], _ c: (Float, Float, Float), _ alpha: Float) {
    var r = [Float](repeating: 0, count: W * W), g = r, b = r, a = r
    for i in 0..<W * W {
        let al = m[i] * alpha
        a[i] = al; r[i] = c.0 * al; g[i] = c.1 * al; b[i] = c.2 * al
    }
    over(&dst, r: r, g: g, b: b, a: a)
}

func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
func smoothstep(_ t: Float) -> Float {
    let x = max(0, min(1, t)); return x * x * (3 - 2 * x)
}
func srgb(_ hex: UInt32) -> (Float, Float, Float) {
    (Float((hex >> 16) & 255) / 255, Float((hex >> 8) & 255) / 255, Float(hex & 255) / 255)
}

// MARK: - Build

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
var canvas = Buf()

let cardPath = continuousRoundedRect(s(CARD_INSET), s(CARD_INSET),
                                    s(1024 - CARD_INSET), s(1024 - CARD_INSET),
                                    s((1024 - 2 * CARD_INSET) / 2))
let cardMask = mask(cardPath)

// --- the card's own drop shadow
let cardShadow = offsetY(blur(cardMask, radius: Int(s(13))), Int(s(12)))
fill(&canvas, cardShadow, (0, 0, 0), 0.30)

// --- card: a gradient that travels green → teal → deep cyan rather than
// darkening a single hue, plus a broad sheen off the top left.
// Sampled straight off the icon this replaces: its bubble ran #7BCBFA at the
// top through teal to #0EBC5F, over a #00AF57 plate. Blue only ever held the
// top sliver before turning green, so the stops are weighted the same way.
let palette = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "chat"
let stops: [(Float, (Float, Float, Float))] = {
    switch palette {
    case "even":  // the same hues spread evenly, for comparison
        return [(0.0, srgb(0x7BCBFA)), (0.5, srgb(0x23BB82)), (1.0, srgb(0x00AF57))]
    case "teal":  // the earlier mint-to-cyan ramp
        return [(0.0, srgb(0x5BF0B4)), (0.5, srgb(0x14B58C)), (1.0, srgb(0x076C79))]
    default:
        return [(0.0, srgb(0x7BCBFA)), (0.22, srgb(0x4FC3C4)),
                (0.52, srgb(0x14B972)), (0.82, srgb(0x00AF57)), (1.0, srgb(0x00A04F))]
    }
}()
let sheenStrength: Float = palette == "teal" ? 0.26 : 0.13

/// The card's colour at a given row — also used as bounce light on the glyph.
func cardColour(_ y: Float) -> (Float, Float, Float) {
    let y0 = Float(s(CARD_INSET)), y1 = Float(s(1024 - CARD_INSET))
    let t = max(0, min(1, (y - y0) / (y1 - y0)))
    for i in 1..<stops.count {
        let (t1, c1) = stops[i]
        guard t <= t1 else { continue }
        let (t0, c0) = stops[i - 1]
        let k = smoothstep((t - t0) / (t1 - t0))
        return (lerp(c0.0, c1.0, k), lerp(c0.1, c1.1, k), lerp(c0.2, c1.2, k))
    }
    return stops[stops.count - 1].1
}

do {
    var r = [Float](repeating: 0, count: W * W), g = r, b = r, a = r
    let sx = Float(s(300)), sy = Float(s(210)), sr = Float(s(760))
    for y in 0..<W {
        let col = cardColour(Float(y))
        for x in 0..<W {
            let i = y * W + x
            guard cardMask[i] > 0 else { continue }
            let dx = Float(x) - sx, dy = Float(y) - sy
            let sheen = (1 - smoothstep(sqrt(dx * dx + dy * dy) / sr)) * sheenStrength
            let al = cardMask[i]
            a[i] = al
            r[i] = min(1, col.0 + sheen) * al
            g[i] = min(1, col.1 + sheen) * al
            b[i] = min(1, col.2 + sheen) * al
        }
    }
    over(&canvas, r: r, g: g, b: b, a: a)
}

// --- top rim light on the card edge
do {
    let edge = mask(cardPath, stroke: s(5))
    var m = [Float](repeating: 0, count: W * W)
    let y0 = Float(s(CARD_INSET)), span = Float(s(520))
    for y in 0..<W {
        let f = 1 - smoothstep((Float(y) - y0) / span)
        for x in 0..<W { m[y * W + x] = edge[y * W + x] * cardMask[y * W + x] * f }
    }
    fill(&canvas, m, (1, 1, 1), 0.5)
}

// MARK: - The bubbles

/// Frosted glass: the backdrop showing through, blurred and lifted towards
/// white, with a lit top edge. That edge is the tell that it is a surface.
func drawGlass(_ path: CGPath, y0: Double, y1: Double,
               white: Float, edge: Float, blurR: Double) {
    let pm = mask(path)
    fill(&canvas, offsetY(blur(pm, radius: Int(s(10))), Int(s(10))), (0, 0, 0), 0.20)

    let br = blur(canvas.r, radius: Int(s(blurR)))
    let bg = blur(canvas.g, radius: Int(s(blurR)))
    let bb = blur(canvas.b, radius: Int(s(blurR)))
    let ba = blur(canvas.a, radius: Int(s(blurR)))
    var r = [Float](repeating: 0, count: W * W), g = r, b = r, a = r
    let py0 = Float(s(y0)), pspan = Float(s(y1 - y0))
    for i in 0..<W * W {
        guard pm[i] > 0 else { continue }
        // un-premultiply the blurred backdrop before tinting it
        let inv = ba[i] > 0.001 ? 1 / ba[i] : 0
        let t = (Float(i / W) - py0) / pspan
        let w = white * lerp(1.35, 0.65, smoothstep(t))
        let al = pm[i]
        a[i] = al
        r[i] = min(1, lerp(br[i] * inv, 1, w)) * al
        g[i] = min(1, lerp(bg[i] * inv, 1, w)) * al
        b[i] = min(1, lerp(bb[i] * inv, 1, w)) * al
    }
    over(&canvas, r: r, g: g, b: b, a: a)

    let em = mask(path, stroke: s(4))
    var m = [Float](repeating: 0, count: W * W)
    for y in 0..<W {
        let f = 1 - smoothstep((Float(y) - py0) / (pspan * 1.4))
        for x in 0..<W { m[y * W + x] = em[y * W + x] * pm[y * W + x] * f }
    }
    fill(&canvas, m, (1, 1, 1), edge)
}

/// A solid, domed object. The height field comes from the distance to the
/// silhouette, so the shoulder follows the shape rather than a fixed gradient.
func drawSolid(_ path: CGPath, y0: Double, y1: Double, bevel: Double) {
    let bm = mask(path)
    // cast shadow, plus a tight unoffset one so it reads as touching
    fill(&canvas, offsetY(blur(bm, radius: Int(s(13))), Int(s(13))), (0, 0, 0), 0.24)
    fill(&canvas, blur(bm, radius: Int(s(5))), (0, 0, 0), 0.16)

    let dist = insideDistance(bm)
    let bev = Float(s(bevel))
    var height = [Float](repeating: 0, count: W * W)
    for i in 0..<W * W {
        let h = min(1, dist[i] / bev)
        height[i] = sqrt(max(0, 1 - (1 - h) * (1 - h)))   // circular shoulder
    }
    height = blur(height, radius: Int(s(7)))              // take the crease off

    // key light from the upper left; the card bounces its own colour back up
    // into the underside, which is what stops the white reading as flat paint
    let lx: Float = -0.42, ly: Float = -0.60, lz: Float = 0.68
    let bx: Float = 0.20, by: Float = 0.86, bz: Float = 0.47
    let hl = sqrt(lx * lx + ly * ly + (lz + 1) * (lz + 1))
    let relief = Float(s(1)) * 0.62
    var r = [Float](repeating: 0, count: W * W), g = r, b = r, a = r
    let fy0 = Float(s(y0)), fy1 = Float(s(y1))
    for y in 1..<W - 1 {
        for x in 1..<W - 1 {
            let i = y * W + x
            guard bm[i] > 0 else { continue }
            let gx = (height[i + 1] - height[i - 1]) * 0.5 / relief
            let gy = (height[i + W] - height[i - W]) * 0.5 / relief
            let len = sqrt(gx * gx + gy * gy + 1)
            let nx = -gx / len, ny = -gy / len, nz = 1 / len

            let diff = max(0, nx * lx + ny * ly + nz * lz)
            // Blinn-Phong: a tight hotspot plus a broad sheen over the shoulder
            let nh = max(0, nx * lx / hl + ny * ly / hl + nz * (lz + 1) / hl)
            let spec = pow(nh, 46) * 0.40 + pow(nh, 5) * 0.14
            // light catching the top-left edge where the surface turns away
            let rim = (1 - smoothstep(dist[i] / (bev * 0.5)))
                * max(0, ny * -0.86 + nx * -0.51) * 0.30

            let t = (Float(y) - fy0) / (fy1 - fy0)
            let albedo = lerp(1.0, 0.93, smoothstep(t))
            // the underside of the shoulder sits in its own shade
            let occl = 1 - (1 - smoothstep(dist[i] / (bev * 0.85)))
                * max(0, ny * 0.9 + nx * 0.45) * 0.16
            let lit = albedo * occl * (0.64 + 0.42 * diff)
            let bounce = max(0, nx * bx + ny * by + nz * bz) * 0.38
            let card = cardColour(Float(y))

            let al = bm[i]
            a[i] = al
            r[i] = min(1, lit + spec + rim + card.0 * bounce) * al
            g[i] = min(1, lit * 1.002 + spec + rim + card.1 * bounce) * al
            b[i] = min(1, lit * 0.995 + spec + rim + card.2 * bounce) * al
        }
    }
    over(&canvas, r: r, g: g, b: b, a: a)
}

struct Spec {
    let x0, y0, x1, y1, r, n: Double
    let tail: Int
    let glass: Bool
    let white: Float, edge: Float, blurR: Double
}

func bubble(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, r: Double,
            n: Double = 5, tail: Int = 0, glass: Bool = false,
            white: Float = 0.22, edge: Float = 0.48, blurR: Double = 28) -> Spec {
    Spec(x0: x0, y0: y0, x1: x1, y1: y1, r: r, n: n, tail: tail, glass: glass,
         white: white, edge: edge, blurR: blurR)
}

let variant = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "dialogue"
let specs: [Spec]
switch variant {
case "dialogue":
    // Two bubbles facing each other, tails on opposite sides: a conversation
    // between two parties rather than a pile of messages.
    specs = [
        bubble(448, 208, 864, 470, r: 94, n: 2.6, tail: -1, glass: true,
               white: 0.22, edge: 0.52, blurR: 30),
        bubble(160, 420, 638, 706, r: 116, n: 2.8, tail: 1),
    ]
case "hero":
    // One bubble, as large as the grid allows, carrying all the material.
    specs = [
        bubble(180, 268, 844, 700, r: 190, n: 3.0, tail: 1),
    ]
case "fan":
    // Three bubbles fanned up and to the right, the back two glass. The one
    // further back is fainter and more diffuse, which is what sells the depth.
    specs = [
        bubble(399, 222, 851, 460, r: 100, n: 2.6, tail: -1, glass: true,
               white: 0.15, edge: 0.34, blurR: 34),
        bubble(311, 304, 787, 542, r: 102, n: 2.6, glass: true,
               white: 0.25, edge: 0.52, blurR: 26),
        bubble(173, 404, 685, 690, r: 118, n: 2.8, tail: 1),
    ]
default:
    fatalError("unknown variant \(variant) — expected dialogue, fan or hero")
}

// MARK: - Icon Composer export
//
// The same geometry, handed to the system instead of shaded here: each bubble
// becomes a flat white SVG layer and macOS 26 supplies the dome, the specular
// pass, the shadows and the appearance variants.
//
// Three things about the .icon format were established by experiment, since none
// of it is in the format's favour:
//
//  * Groups are ordered front to back, so the list below is reversed. Getting
//    this wrong hides the artwork behind whatever is nominally "first".
//  * The system scales layer artwork by 824/1024 about the centre — the same
//    inset as the icon grid — so geometry drawn for the baked icon needs
//    position.scale of 1024/824 to land in the same place.
//  * A background fill takes exactly two colours. A third makes actool throw
//    "attempt to insert nil object", and its `orientation` is ignored, so the
//    four-stop weighting of the baked ramp cannot be expressed here. Faking it
//    with a full-bleed gradient layer would cost the appearance variants, which
//    are the reason to use this format at all, so the ramp stays linear.
//
// Likewise `glass` and `translucency` only drive the Clear appearance; in the
// default one every layer is opaque, so the back bubble's translucency is the
// layer `opacity` instead.

/// A CGPath as SVG path data, back in 1024-space.
func svgPath(_ path: CGPath) -> String {
    var d = ""
    let k = 1.0 / Double(SCALE)
    path.applyWithBlock { e in
        let p = e.pointee.points
        func at(_ i: Int) -> String {
            String(format: "%.2f %.2f", Double(p[i].x) * k, Double(p[i].y) * k)
        }
        switch e.pointee.type {
        case .moveToPoint:       d += "M \(at(0)) "
        case .addLineToPoint:    d += "L \(at(0)) "
        case .addQuadCurveToPoint: d += "Q \(at(0)) \(at(1)) "
        case .addCurveToPoint:   d += "C \(at(0)) \(at(1)) \(at(2)) "
        case .closeSubpath:      d += "Z "
        @unknown default:        break
        }
    }
    return d.trimmingCharacters(in: .whitespaces)
}

func writeIconDocument(_ dir: String) throws {
    let assets = dir + "/Assets"
    try? FileManager.default.removeItem(atPath: dir)
    try FileManager.default.createDirectory(atPath: assets,
                                            withIntermediateDirectories: true)

    func svg(_ body: String) -> String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" \
        viewBox="0 0 1024 1024">
        \(body)
        </svg>

        """
    }

    // One white silhouette per bubble. The glass one keeps its translucency as
    // layer opacity; everything else is the system's job.
    let inset = 1024.0 / (1024.0 - 2 * CARD_INSET)
    var groups: [[String: Any]] = []
    for (i, spec) in specs.enumerated() {
        let name = i == specs.count - 1 ? "Front" : "Back\(i + 1)"
        let d = svgPath(bubblePath(spec.x0, spec.y0, spec.x1, spec.y1, spec.r,
                                  n: spec.n, tail: spec.tail))
        try svg("  <path d=\"\(d)\" fill=\"#FFFFFF\"/>")
            .write(toFile: "\(assets)/\(name).svg", atomically: true, encoding: .utf8)

        var layer: [String: Any] = [
            "blend-mode": "normal",
            "glass": false,
            "hidden": false,
            "image-name": "\(name).svg",
            "name": name,
            "position": ["scale": inset, "translation-in-points": [0, 0]],
        ]
        if spec.glass { layer["opacity"] = 0.45 }
        groups.append([
            "layers": [layer],
            "lighting": "individual",
            "shadow": ["kind": "neutral", "opacity": 0.5],
            "specular": true,
            "translucency": ["enabled": true, "value": 0.5],
        ])
    }

    let doc: [String: Any] = [
        "fill": ["linear-gradient": [srgbString(stops[0].1),
                                     srgbString(stops[stops.count - 1].1)]],
        "groups": Array(groups.reversed()),   // the format lists front to back
        "supported-platforms": ["circles": ["watchOS"], "squares": "shared"],
    ]
    let json = try JSONSerialization.data(withJSONObject: doc,
                                          options: [.prettyPrinted, .sortedKeys])
    try json.write(to: URL(fileURLWithPath: dir + "/icon.json"))
    print("wrote \(dir)")
}

func srgbString(_ c: (Float, Float, Float)) -> String {
    String(format: "extended-srgb:%.5f,%.5f,%.5f,1.00000", c.0, c.1, c.2)
}

if CommandLine.arguments.contains("--icon") {
    try writeIconDocument(out + "/AppIcon.icon")
    exit(0)
}

for spec in specs {
    let path = bubblePath(spec.x0, spec.y0, spec.x1, spec.y1, spec.r,
                          n: spec.n, tail: spec.tail)
    // a tail hangs 39% of the body height below it; shading spans the lot
    let bottom = spec.tail == 0 ? spec.y1
        : spec.y1 + (spec.y1 - spec.y0) * 0.391
    if spec.glass {
        drawGlass(path, y0: spec.y0, y1: spec.y1,
                  white: spec.white, edge: spec.edge, blurR: spec.blurR)
    } else {
        drawSolid(path, y0: spec.y0, y1: bottom, bevel: 105)
    }
}

// MARK: - Output

func writePNG(_ buf: Buf, size: Int, path: String) {
    // repeated 2x2 box downsampling — every target size is a power of two
    var w = W
    var r = buf.r, g = buf.g, b = buf.b, a = buf.a
    while w > size {
        let h = w / 2
        var nr = [Float](repeating: 0, count: h * h), ng = nr, nb = nr, na = nr
        for y in 0..<h {
            for x in 0..<h {
                let i0 = (2 * y) * w + 2 * x, i1 = i0 + 1
                let i2 = (2 * y + 1) * w + 2 * x, i3 = i2 + 1
                let j = y * h + x
                nr[j] = (r[i0] + r[i1] + r[i2] + r[i3]) / 4
                ng[j] = (g[i0] + g[i1] + g[i2] + g[i3]) / 4
                nb[j] = (b[i0] + b[i1] + b[i2] + b[i3]) / 4
                na[j] = (a[i0] + a[i1] + a[i2] + a[i3]) / 4
            }
        }
        r = nr; g = ng; b = nb; a = na; w = h
    }

    var bytes = [UInt8](repeating: 0, count: w * w * 4)
    for i in 0..<w * w {
        bytes[i * 4 + 0] = UInt8(max(0, min(255, r[i] * 255 + 0.5)))
        bytes[i * 4 + 1] = UInt8(max(0, min(255, g[i] * 255 + 0.5)))
        bytes[i * 4 + 2] = UInt8(max(0, min(255, b[i] * 255 + 0.5)))
        bytes[i * 4 + 3] = UInt8(max(0, min(255, a[i] * 255 + 0.5)))
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let img = CGImage(width: w, height: w, bitsPerComponent: 8, bitsPerPixel: 32,
                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGBitmapInfo(rawValue:
                        CGImageAlphaInfo.premultipliedLast.rawValue),
                      provider: provider, decode: nil, shouldInterpolate: false,
                      intent: .defaultIntent)!
    let rep = NSBitmapImageRep(cgImage: img)
    rep.size = NSSize(width: w, height: w)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

for size in SIZES {
    writePNG(canvas, size: size, path: "\(out)/AppIcon-\(size).png")
}
