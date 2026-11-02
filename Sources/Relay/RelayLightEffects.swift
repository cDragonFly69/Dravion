import SwiftUI
import RelayCore

// Lancer Light UI (MIT), native Canvas adaptation of geometry.ts/svg.ts/running-border.css.
// Original sources and notices: third_party/lancer-light-ui; see docs/source-provenance.md.
struct RelayLightAnchors: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

extension View {
    func relayLightAnchor(_ id: String) -> some View {
        anchorPreference(key: RelayLightAnchors.self, value: .bounds) { [id: $0] }
    }
}

/// Anchors must exist and be visible in their own scroll viewport. Missing/offscreen anchors cancel a visual
/// emission; they never point to another node. No frame loop exists while idle, hidden, or in reduced-motion mode.
struct RelayLightLayer: View {
    let graph: RelayTrajectory
    let frames: [String: CGRect]
    let selectedNodeID: String?
    let historyReady: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var tracker = RelayLightTracker()
    @State private var emissions: [Emission] = []

    private struct Emission: Identifiable {
        var id: String
        var date: Date
        var seed: CGFloat
    }
    private struct Snapshot: Equatable { var ready: Bool; var ids: [String] }
    private var snapshot: Snapshot { .init(ready: historyReady, ids: graph.nodes.map(\.id)) }

    var body: some View {
        ZStack {
            Canvas { context, _ in
                if let id = selectedNodeID, let node = graph.nodes.first(where: { $0.id == id }),
                   let endpoints = endpoints(node) {
                    let route = RelayLightGeometry.curve(from: endpoints.0, to: endpoints.1, seed: 0.2)
                    context.stroke(path(route), with: .color(color(node).opacity(0.35)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                }
            }
            if !emissions.isEmpty, !reduceMotion, scenePhase == .active {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { clock in
                    Canvas { context, _ in
                        for emission in emissions {
                            guard let node = graph.nodes.first(where: { $0.id == emission.id }),
                                  let endpoints = endpoints(node) else { continue }
                            draw(emission, from: endpoints.0, to: endpoints.1, tint: color(node), now: clock.date, context: &context)
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
        .onChange(of: snapshot, initial: true) { _, value in
            let added = tracker.observe(value.ids, ready: value.ready)
            guard !reduceMotion, scenePhase == .active else { emissions = []; return }
            let now = Date()
            let visible = added.filter { id in graph.nodes.first(where: { $0.id == id }).flatMap(endpoints) != nil }
            emissions = Array((emissions.filter { now.timeIntervalSince($0.date) < RelayLightGeometry.flightSeconds + RelayLightGeometry.landingSeconds } + visible.map {
                Emission(id: $0, date: now, seed: CGFloat($0.utf8.reduce(UInt64(0)) { ($0 &* 31 &+ UInt64($1)) % 65521 }) / 65521)
            }).suffix(4))
        }
        .onChange(of: reduceMotion) { _, _ in emissions = [] }
        .onChange(of: scenePhase) { _, _ in emissions = [] }
        .task(id: emissions.map(\.id)) {
            guard !emissions.isEmpty else { return }
            // Sleep only throws for task cancellation; a replaced animation must not clear the next emission.
            try? await Task.sleep(for: .seconds(RelayLightGeometry.flightSeconds + RelayLightGeometry.landingSeconds))
            guard !Task.isCancelled else { return }
            emissions = []
        }
        .onDisappear { emissions = [] }
    }

    private func endpoints(_ node: RelayTrajectoryNode) -> (CGPoint, CGPoint)? {
        guard let threadID = node.threadItemID, let source = frames["message:\(threadID)"], let target = frames["node:\(node.id)"],
              let conversation = frames["thread-viewport"], let tree = frames["trajectory-viewport"] else { return nil }
        let a = CGPoint(x: source.maxX, y: source.midY), b = CGPoint(x: target.midX, y: target.midY)
        guard conversation.insetBy(dx: -1, dy: 0).contains(a), tree.contains(b) else { return nil }
        return (a, b)
    }

    private func color(_ node: RelayTrajectoryNode) -> Color {
        guard let lane = graph.lanes.first(where: { $0.id == node.laneID }), lane.id != RelayTrajectory.youLane else { return .primary }
        return RelayStyle.color(lane.colorName)
    }

    private func path(_ curve: RelayLightGeometry.Curve) -> Path {
        Path { path in path.move(to: curve.a); path.addCurve(to: curve.b, control1: curve.c1, control2: curve.c2) }
    }

    private func draw(_ emission: Emission, from a: CGPoint, to b: CGPoint, tint: Color, now: Date, context: inout GraphicsContext) {
        let age = max(0, now.timeIntervalSince(emission.date))
        if age >= RelayLightGeometry.flightSeconds {
            let p = CGFloat((age - RelayLightGeometry.flightSeconds) / RelayLightGeometry.landingSeconds)
            guard p < 1 else { return }
            let radius = 6 + 12 * RelayLightGeometry.smoothstep(p)
            context.stroke(Path(ellipseIn: CGRect(x: b.x - radius, y: b.y - radius, width: 2 * radius, height: 2 * radius)),
                           with: .color(tint.opacity(Double(1 - p) * 0.6)), lineWidth: 1.3)
            return
        }
        let progress = CGFloat(age / RelayLightGeometry.flightSeconds)
        let curve = RelayLightGeometry.curve(from: a, to: b, seed: emission.seed)
        let flight = RelayLightGeometry.flight(curve, progress: progress)
        let trail = path(curve).trimmedPath(from: flight.startFraction, to: flight.endFraction)
        for (width, opacity) in [(6.0, 0.07), (2.6, 0.13)] {
            context.stroke(trail, with: .color(tint.opacity(opacity)), style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
        context.stroke(trail, with: .linearGradient(Gradient(colors: [tint.opacity(0), tint]), startPoint: flight.tail, endPoint: flight.head),
                       style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
        for (radius, opacity) in [(6.0, 0.16), (2.2, 1.0)] {
            context.fill(Path(ellipseIn: CGRect(x: flight.head.x - radius, y: flight.head.y - radius, width: radius * 2, height: radius * 2)),
                         with: .color(tint.opacity(opacity)))
        }
        if progress < 0.55 {
            let launch = progress / 0.55, radius = 10 + launch * 8
            context.stroke(Path(ellipseIn: CGRect(x: a.x - radius, y: a.y - radius, width: radius * 2, height: radius * 2)),
                           with: .color(tint.opacity(Double(1 - launch) * 0.4)), lineWidth: 1.2)
        }
    }
}

struct RelayRunningBorder: View {
    let color: Color
    var radius: CGFloat = 11
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Group {
            if reduceMotion || scenePhase != .active {
                RoundedRectangle(cornerRadius: radius).stroke(color.opacity(0.55), lineWidth: 1.2)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { clock in
                    Canvas { context, size in
                        let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
                        let r = min(radius, rect.height / 2)
                        let perimeter = 2 * (rect.width + rect.height - 4 * r) + 2 * .pi * r
                        let phase = CGFloat(clock.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: RelayLightGeometry.borderSeconds) / RelayLightGeometry.borderSeconds)
                        let outline = Path(roundedRect: rect, cornerRadius: r)
                        context.stroke(outline, with: .color(color), style: StrokeStyle(lineWidth: 1.2, lineCap: .round,
                                       dash: [perimeter * 0.09, perimeter * 0.91], dashPhase: -phase * perimeter))
                    }
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
