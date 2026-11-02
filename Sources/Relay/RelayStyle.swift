import SwiftUI
import RelayCore

/// Dravion brand (assets/brand/README.md). The desktop app follows DeepSeek Harness and Codex: neutral surfaces,
/// black text and ink actions; the brand gradient (Ember → Magenta → Violet) only on the mark and the app icon.
enum DravionBrand {
    static let ember = Color(red: 1.0, green: 0.541, blue: 0.239)        // #FF8A3D
    static let magenta = Color(red: 0.898, green: 0.188, blue: 0.420)    // #E5306B
    static let violet = Color(red: 0.357, green: 0.169, blue: 0.878)     // #5B2BE0
    /// Ink in light mode, Mist in dark mode; solid even on the translucent sidebar, where .primary turns grey.
    static let solidInk = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(srgbRed: 0.961, green: 0.953, blue: 1.0, alpha: 1) : NSColor(srgbRed: 0.055, green: 0.063, blue: 0.125, alpha: 1)
    })
    static let ink = Color(red: 0.055, green: 0.063, blue: 0.125)        // #0E1020
    static let mist = Color(red: 0.961, green: 0.953, blue: 1.0)         // #F5F3FF
    static let gradient = LinearGradient(colors: [ember, magenta, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// The Dravion mark: a D whose stem rises into a horn, with a slit-pupil eye cut out (dravion-mark.svg, 256-unit box).
struct DravionMark: View {
    enum Fill { case ink, gradient }
    var size: CGFloat = 28
    var fill: Fill = .ink
    var body: some View {
        Canvas { context, canvas in
            let k = canvas.width / 256
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
            var body = Path()
            body.move(to: p(56, 220)); body.addLine(to: p(56, 66))
            body.addCurve(to: p(22, 8), control1: p(53, 46), control2: p(43, 27))
            body.addCurve(to: p(106, 36), control1: p(50, 17), control2: p(78, 29))
            body.addLine(to: p(140, 36))
            body.addCurve(to: p(232, 128), control1: p(196, 36), control2: p(232, 78))
            body.addCurve(to: p(140, 220), control1: p(232, 178), control2: p(196, 220))
            body.closeSubpath()
            // The eye is cut out of the body (even-odd), the pupil drawn back inside it.
            body.move(to: p(92, 128))
            body.addCurve(to: p(196, 128), control1: p(114, 96), control2: p(174, 96))
            body.addCurve(to: p(92, 128), control1: p(174, 160), control2: p(114, 160))
            body.closeSubpath()
            var pupil = Path()
            pupil.move(to: p(144, 103))
            pupil.addCurve(to: p(144, 153), control1: p(153, 115), control2: p(153, 141))
            pupil.addCurve(to: p(144, 103), control1: p(135, 141), control2: p(135, 115))
            pupil.closeSubpath()
            let shading: GraphicsContext.Shading = fill == .ink
                ? .color(DravionBrand.solidInk)
                : .linearGradient(Gradient(colors: [DravionBrand.ember, DravionBrand.magenta, DravionBrand.violet]),
                                  startPoint: .zero, endPoint: CGPoint(x: canvas.width, y: canvas.height))
            context.fill(body, with: shading, style: FillStyle(eoFill: true))
            context.fill(pupil, with: shading)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Dravion")
    }
}

enum RelayStyle {
    /// Brand highlight for states and marks (running, restricted, focus); never for body text.
    static let accent = DravionBrand.magenta
    /// Primary actions are ink, as in Codex: black buttons and black text on the main page.
    static let action = DravionBrand.solidInk
    static let canvas = Color(nsColor: .textBackgroundColor)
    static let surface = Color(nsColor: .textBackgroundColor)
    static let sunken = Color.primary.opacity(0.035)
    static let border = Color.primary.opacity(0.09)
    /// The selected sidebar row: neutral grey in light and dark, focused or not (AGENTS.md "界面规范" 1–2).
    static let sidebarSelection = Color.primary.opacity(0.09)
    static func color(_ name: String) -> Color {
        switch name {
        case "clay": return accent
        case "teal": return .teal
        case "violet": return .purple
        case "amber": return .orange
        case "green": return .green
        default: return .blue
        }
    }
    static func status(_ state: RelayRunStatus) -> Color {
        if state.isWorking { return accent }
        switch state {
        case .succeeded: return .green
        case .paused, .interrupted: return .orange
        case .failed, .budgetExceeded: return .red
        default: return .secondary
        }
    }
}

struct RelayCard<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(RelayStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(RelayStyle.border, lineWidth: 1))
    }
}

struct RelayBadge: View {
    var text: String
    var color: Color = .secondary
    var body: some View {
        HStack(spacing: 5) { Circle().fill(color).frame(width: 5, height: 5); Text(text) }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 9).padding(.vertical, 5).background(color.opacity(0.09), in: Capsule())
    }
}

struct RelayPageTitle: View {
    var title: String
    var subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 28, weight: .semibold, design: .rounded))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RelayEmpty: View {
    var symbol: String
    /// Phosphor icon (preferred, see 界面规范 3); `symbol` is the SF fallback.
    var icon: String? = nil
    var title: String
    var detail: String
    var body: some View {
        VStack(spacing: 12) {
            RelayIconTile(symbol: symbol, icon: icon, size: 56)
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }.frame(maxWidth: .infinity).padding(.vertical, 32)
    }
}

struct RelaySheetHeader: View {
    var title: String
    var close: () -> Void
    var body: some View {
        HStack {
            Text(title).font(.system(size: 20, weight: .semibold))
            Spacer()
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)) }
                .buttonStyle(.plain).padding(7).background(.quaternary, in: Circle()).accessibilityLabel("关闭")
        }.padding(24)
    }
}

extension View {
    func relayField() -> some View {
        self.textFieldStyle(.plain).padding(9).background(RelayStyle.surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(RelayStyle.border, lineWidth: 1))
    }
}

/// A rounded white tile with a hairline border and a coloured glyph (the settings rows of DeepSeek Harness).
struct RelayIconTile: View {
    /// SF Symbol name; ignored when `icon` names a Phosphor icon.
    var symbol: String = ""
    /// Phosphor icon name (preferred; see AGENTS.md "界面规范").
    var icon: String? = nil
    var color: Color = .primary
    var size: CGFloat = 40
    var body: some View {
        Group {
            if let icon { DravionIcon(name: icon, size: size * 0.48) }
            else { Image(systemName: symbol).font(.system(size: size * 0.42, weight: .medium)) }
        }.foregroundStyle(color)
            .frame(width: size, height: size)
            .background(RelayStyle.surface, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).stroke(RelayStyle.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
    }
}

/// Pixel lettering for the wordmark and its tag (user request, 2026-11-01): square 5×7 glyphs drawn as blocks, in
/// the surrounding foreground colour. Only the letters the brand uses are defined; others draw as a gap.
struct RelayPixelText: View {
    var text: String
    /// Side of one pixel, in points.
    var pixel: CGFloat = 2.5
    static let glyphs: [Character: [String]] = [
        "D": ["11110", "10001", "10001", "10001", "10001", "10001", "11110"],
        "r": ["00000", "00000", "10110", "11001", "10000", "10000", "10000"],
        "a": ["00000", "00000", "01110", "00001", "01111", "10001", "01111"],
        "v": ["00000", "00000", "10001", "10001", "10001", "01010", "00100"],
        "i": ["00100", "00000", "01100", "00100", "00100", "00100", "01110"],
        "o": ["00000", "00000", "01110", "10001", "10001", "10001", "01110"],
        "n": ["00000", "00000", "10110", "11001", "10001", "10001", "10001"],
        "B": ["11110", "10001", "10001", "11110", "10001", "10001", "11110"],
        "O": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
        "T": ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
    ]
    var body: some View {
        let characters = Array(text)
        Canvas { context, _ in
            var path = Path()
            for (index, character) in characters.enumerated() {
                let left = CGFloat(index * 6) * pixel
                for (row, line) in (Self.glyphs[character] ?? []).enumerated() {
                    for (column, bit) in line.enumerated() where bit == "1" {
                        path.addRect(CGRect(x: left + CGFloat(column) * pixel, y: CGFloat(row) * pixel, width: pixel, height: pixel))
                    }
                }
            }
            context.fill(path, with: .foreground)
        }
        .frame(width: CGFloat(max(0, characters.count * 6 - 1)) * pixel, height: 7 * pixel)
        .accessibilityElement().accessibilityLabel(text)
    }
}

/// The product tag next to the wordmark, like DeepSeek Harness's "HARNESS".
struct RelayProductTag: View {
    var text: String
    var body: some View {
        // Square corners and pixel letters, like the wordmark.
        RelayPixelText(text: text, pixel: 1.5).foregroundStyle(Color(nsColor: .textBackgroundColor))
            .padding(.horizontal, 4.5).padding(.vertical, 3).background(DravionBrand.solidInk, in: Rectangle())
    }
}

/// A Phosphor icon (MIT, Sources/Relay/Icons/phosphor) drawn as a template, so it takes the surrounding colour.
/// The sidebar uses the regular weight and duotone for the selected row (AGENTS.md "界面规范").
struct DravionIcon: View {
    var name: String
    var duotone = false
    var size: CGFloat = 17
    /// Icon set folder under `Icons/`: `phosphor` (navigation, tiles) or `element-plus` (control glyphs).
    var set = "phosphor"
    private static var cache: [String: NSImage] = [:]
    private static func image(_ file: String, set: String) -> NSImage? {
        if let cached = cache["\(set)/\(file)"] { return cached }
        guard let url = Bundle.module.url(forResource: file, withExtension: "svg", subdirectory: "Icons/\(set)"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        cache["\(set)/\(file)"] = image
        return image
    }
    var body: some View {
        if let image = Self.image(duotone ? "\(name)-duotone" : name, set: set) {
            Image(nsImage: image).renderingMode(.template).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: "questionmark.square.dashed").frame(width: size, height: size)
        }
    }
}

/// Token counts always carry their unit: "820 tokens", "12.4K tokens", "3.1M tokens".
enum RelayTokens {
    static func number(_ value: Int) -> String {
        let n = Double(value)
        if value >= 1_000_000 { return String(format: n >= 10_000_000 ? "%.0fM" : "%.1fM", n / 1_000_000) }
        if value >= 1_000 { return String(format: n >= 100_000 ? "%.0fK" : "%.1fK", n / 1_000) }
        return "\(value)"
    }
    static func text(_ value: Int) -> String { number(value) + " tokens" }
}

/// Soft accent colours for categories (stats, clients, stages). Used as tints and small marks, never for body
/// text; still no blue as the theme colour (界面规范).
enum RelayPalette {
    static let violet = DravionBrand.violet
    static let rose = DravionBrand.magenta
    static let ember = DravionBrand.ember
    static let amber = Color(red: 0.93, green: 0.62, blue: 0.10)
    static let green = Color(red: 0.16, green: 0.62, blue: 0.38)
    static let teal = Color(red: 0.06, green: 0.58, blue: 0.56)
    /// Stage colours: plan, execute, test, review.
    static let stages: [Color] = [violet, ember, teal, green]
    static func stage(_ status: RelayRunStatus) -> Color {
        switch status {
        case .planning: return stages[0]
        case .executing: return stages[1]
        case .testing: return stages[2]
        case .reviewing: return stages[3]
        default: return .secondary
        }
    }
    static func client(_ name: String) -> Color {
        switch name {
        case "Claude Code": return ember
        case "Codex": return Color(red: 0.2, green: 0.2, blue: 0.25)
        case "WorkBuddy": return violet
        case "DeepSeek Harness": return teal
        default: return amber
        }
    }
}

/// A tinted number tile: label, big value, note, with the category colour as a wash and a left rule.
struct RelayStatTile: View {
    var title: String
    var value: String
    var note: String
    var color: Color
    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3).padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
                Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }.padding(.leading, 12)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(color.opacity(0.16)))
    }
}

/// Notices and errors close by themselves (user request, 2026-11-02: “顶部的通知需要自动关闭……提醒也是”), unless the
/// pointer rests on them; the close button stays. A new message restarts the clock.
struct RelayAutoDismiss: ViewModifier {
    let key: String?
    let seconds: Double
    let dismiss: () -> Void
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .onHover { hovering = $0 }
            .task(id: "\(key ?? "")|\(hovering)") {
                guard key != nil, !hovering else { return }
                try? await Task.sleep(for: .seconds(seconds))
                if !Task.isCancelled, !hovering { withAnimation(.easeOut(duration: 0.25)) { dismiss() } }
            }
    }
}
