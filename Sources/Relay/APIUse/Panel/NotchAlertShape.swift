// Copyright (c) 2026 qunqin24. Licensed under the Apache License, Version 2.0.
import SwiftUI

/// The collapsed alert cue for a top-docked rail whose ordinary sliver is
/// replaced by the Mac's camera housing. It sits immediately under the
/// physical notch and stays narrower than it, so it reads as the housing's
/// status edge rather than as a second rail.
struct NotchAlertShape: Shape {
    var notchSize: CGSize

    func path(in rect: CGRect) -> Path {
        let height = max(2 * PanelMetrics.scale, 1)
        let sideInset = min(12 * PanelMetrics.scale, notchSize.width / 4)
        let width = max(notchSize.width - sideInset * 2, height)
        let indicator = CGRect(
            x: rect.midX - width / 2,
            y: min(rect.minY + notchSize.height, rect.maxY - height),
            width: width,
            height: height
        )
        return Path(roundedRect: indicator, cornerRadius: height / 2)
    }
}

/// What the agents are doing, for a rail collapsed into the housing, drawn on
/// the same status edge as the alert: studied from codenotch, whose collapsed
/// notch says *working*, *waiting on you* or *done* (approach only, no code).
enum DockActivity: Equatable {
    case working
    case waiting
    case finished
}

/// A piece of `NotchAlertShape`'s edge, `start` and `length` as fractions of
/// it, so a segment can travel along under the housing.
struct NotchEdgeSegment: Shape {
    var notchSize: CGSize
    var start: CGFloat
    var length: CGFloat

    var animatableData: CGFloat {
        get { start }
        set { start = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let full = NotchAlertShape(notchSize: notchSize).path(in: rect).boundingRect
        let piece = CGRect(x: full.minX + full.width * start, y: full.minY,
                           width: full.width * length, height: full.height)
        return Path(roundedRect: piece, cornerRadius: full.height / 2)
    }
}

/// The activity edge: a white segment travelling while an agent works, amber
/// breathing while one waits on the user, green while a finished turn is
/// fresh. Core Animation drives the motion, as for the ring's marks.
struct NotchActivityEdge: View {
    let notchSize: CGSize
    let activity: DockActivity
    var animates = true
    @State private var phase = false

    var body: some View {
        Group {
            switch activity {
            case .working:
                NotchEdgeSegment(notchSize: notchSize, start: animates && phase ? 0.7 : 0, length: 0.3)
                    .fill(Color.white)
                    .animation(animates ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : nil, value: phase)
            case .waiting:
                NotchAlertShape(notchSize: notchSize)
                    .fill(Color.orange)
                    .opacity(animates ? (phase ? 1 : 0.3) : 1)
                    .animation(animates ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : nil, value: phase)
            case .finished:
                // Fades itself: nothing else redraws the rail when the few
                // seconds a finish counts as fresh run out.
                NotchAlertShape(notchSize: notchSize).fill(Color.green)
                    .opacity(phase ? 0 : 1)
                    .animation(.easeIn(duration: 1).delay(4), value: phase)
            }
        }
        // Reset on the way out, or a second appearance sets an already-true
        // value and nothing animates.
        .onAppear { phase = true }
        .onDisappear { phase = false }
        .id(activity)
    }
}
