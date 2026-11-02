// Renders the desktop app icons (1024 px).
// Usage: swiftc -O -parse-as-library -o /tmp/render-icons Scripts/render-icons.swift && /tmp/render-icons Assets/icon-source
// The app icon is a cream tile (solid, like the api-use icon, not a hollow white) with the mark in the brand
// gradient, Ember → Magenta → Vision Violet. Two other cream tones and the ink variant are kept as alternatives.
import SwiftUI
import AppKit

// Dravion mark (assets/brand/dravion-mark.svg, 256-unit box): body with the eye cut out, plus the pupil.
func markBody(_ r: CGRect) -> Path {
    let k = r.width / 256
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * k, y: r.minY + y * k) }
    var b = Path()
    b.move(to: p(56, 220)); b.addLine(to: p(56, 66))
    b.addCurve(to: p(22, 8), control1: p(53, 46), control2: p(43, 27))
    b.addCurve(to: p(106, 36), control1: p(50, 17), control2: p(78, 29))
    b.addLine(to: p(140, 36))
    b.addCurve(to: p(232, 128), control1: p(196, 36), control2: p(232, 78))
    b.addCurve(to: p(140, 220), control1: p(232, 178), control2: p(196, 220))
    b.closeSubpath()
    b.move(to: p(92, 128))
    b.addCurve(to: p(196, 128), control1: p(114, 96), control2: p(174, 96))
    b.addCurve(to: p(92, 128), control1: p(174, 160), control2: p(114, 160))
    b.closeSubpath()
    return b
}
func markPupil(_ r: CGRect) -> Path {
    let k = r.width / 256
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * k, y: r.minY + y * k) }
    var q = Path()
    q.move(to: p(144, 103))
    q.addCurve(to: p(144, 153), control1: p(153, 115), control2: p(153, 141))
    q.addCurve(to: p(144, 103), control1: p(135, 141), control2: p(135, 115))
    q.closeSubpath()
    return q
}
struct Mark: Shape { func path(in r: CGRect) -> Path { var p = markBody(r); p.addPath(markPupil(r)); return p } }
struct MarkBody: Shape { func path(in r: CGRect) -> Path { markBody(r) } }

let ink = Color(red: 0.055, green: 0.063, blue: 0.125)
let ember = Color(red: 1.0, green: 0.541, blue: 0.239)        // #FF8A3D
let magenta = Color(red: 0.898, green: 0.188, blue: 0.420)    // #E5306B
let violet = Color(red: 0.357, green: 0.169, blue: 0.878)     // #5B2BE0
let brand = LinearGradient(colors: [ember, magenta, violet], startPoint: .topLeading, endPoint: .bottomTrailing)

struct Cream { var top: Color; var bottom: Color; var rim: Color }
let ivory = Cream(top: Color(red: 0.992, green: 0.980, blue: 0.957), bottom: Color(red: 0.945, green: 0.918, blue: 0.875), rim: Color(red: 0.85, green: 0.80, blue: 0.73))
let cream = Cream(top: Color(red: 0.984, green: 0.961, blue: 0.918), bottom: Color(red: 0.925, green: 0.882, blue: 0.812), rim: Color(red: 0.80, green: 0.73, blue: 0.63))
let sand = Cream(top: Color(red: 0.973, green: 0.937, blue: 0.875), bottom: Color(red: 0.898, green: 0.835, blue: 0.741), rim: Color(red: 0.76, green: 0.67, blue: 0.55))

// macOS icon grid: 1024 canvas, 824 body, continuous corners.
struct CreamTile<Content: View>: View {
    var tone: Cream
    @ViewBuilder var content: Content
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 185, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [tone.top, tone.bottom], startPoint: .top, endPoint: .bottom))
                // Lit from above: a soft sheen on the upper half and a warm rim, so the tile reads as a solid object.
                .overlay(shape.fill(RadialGradient(colors: [.white.opacity(0.55), .clear], center: .init(x: 0.5, y: 0.0), startRadius: 0, endRadius: 560)))
                .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.95), tone.rim.opacity(0.55)], startPoint: .top, endPoint: .bottom), lineWidth: 5))
                .shadow(color: Color(red: 0.35, green: 0.25, blue: 0.15).opacity(0.28), radius: 26, y: 14)
            content
        }.frame(width: 824, height: 824).frame(width: 1024, height: 1024)
    }
}

/// The mark in the brand gradient with a glossy top light and a soft drop shadow (the depth of api-use's D).
struct GlossyMark: View {
    var body: some View {
        ZStack {
            MarkBody().fill(brand, style: FillStyle(eoFill: true))
                .shadow(color: magenta.opacity(0.35), radius: 22, y: 14)
            MarkBody().fill(LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0.0)], startPoint: .top, endPoint: .center), style: FillStyle(eoFill: true))
            PupilShape().fill(LinearGradient(colors: [ember, magenta], startPoint: .top, endPoint: .bottom))
        }
    }
}

struct CreamIcon: View {
    var tone: Cream
    var body: some View { CreamTile(tone: tone) { GlossyMark().frame(width: 540, height: 540).offset(x: 10, y: -4) } }
}

// Alternative: ink mark on ivory, closest to DeepSeek Harness.
struct InkIcon: View { var body: some View {
    CreamTile(tone: ivory) { Mark().fill(ink, style: FillStyle(eoFill: true)).frame(width: 520, height: 520).offset(x: 10) }
} }

// The mark alone (widget brand image).
struct MarkOnly: View { var body: some View { GlossyMark().frame(width: 512, height: 512) } }
struct PupilShape: Shape { func path(in r: CGRect) -> Path { markPupil(r) } }

@MainActor func save<V: View>(_ view: V, _ name: String) {
    let r = ImageRenderer(content: view); r.scale = 1
    guard let cg = r.cgImage else { fatalError("render failed") }
    let rep = NSBitmapImageRep(cgImage: cg)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "/" + name))
}
@main struct Render {
    @MainActor static func main() {
        save(CreamIcon(tone: cream), "icon-cream.png")
        save(CreamIcon(tone: ivory), "icon-ivory.png")
        save(CreamIcon(tone: sand), "icon-sand.png")
        save(InkIcon(), "icon-ink.png")
        save(MarkOnly(), "mark-gradient.png")
    }
}
