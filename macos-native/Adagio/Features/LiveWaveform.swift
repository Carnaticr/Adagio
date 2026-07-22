import SwiftUI

/// Live scrolling bar waveform for the recorder, drawn with Canvas.
struct LiveWaveform: View {
    let peaks: [Float]
    let active: Bool

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Color.black.opacity(0.25)))
            let barW: CGFloat = 3
            let gap: CGFloat = 1
            let n = max(1, Int(size.width / (barW + gap)))
            let slice = peaks.suffix(n)
            let midY = size.height / 2
            var x = size.width - CGFloat(slice.count) * (barW + gap)
            for peak in slice {
                let amp = max(0.02, CGFloat(peak))
                let h = amp * (size.height - 16)
                let rect = CGRect(x: x, y: midY - h / 2, width: barW, height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.2),
                             with: .color(.accentColor))
                x += barW + gap
            }
        }
        .background(Color.black.opacity(0.2))
    }
}

/// Static waveform with silence shading, cut markers, and a playhead — used by the
/// Split editor. Reports click/drag positions in seconds via callbacks.
struct SplitWaveform: View {
    let peaks: [Float]
    let silences: [SilenceDetector.Range]
    let cuts: [Double]
    let duration: Double
    let playhead: Double
    let onAddCut: (Double) -> Void
    let onMoveCut: (Int, Double) -> Void
    let onRemoveCut: (Int) -> Void

    @State private var dragging: Int? = nil

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            Canvas { context, size in
                // silence shading
                for s in silences {
                    let x1 = xFor(s.start, w: size.width)
                    let x2 = xFor(s.end, w: size.width)
                    context.fill(Path(CGRect(x: x1, y: 0, width: max(1, x2 - x1), height: size.height)),
                                 with: .color(.orange.opacity(0.12)))
                }
                // waveform
                let n = peaks.count
                if n > 0 {
                    let step = size.width / CGFloat(n)
                    for (i, p) in peaks.enumerated() {
                        let amp = max(0.015, CGFloat(p))
                        let bh = amp * (size.height - 24)
                        let rect = CGRect(x: CGFloat(i) * step, y: size.height / 2 - bh / 2,
                                          width: max(1, step - 0.4), height: bh)
                        context.fill(Path(rect), with: .color(.accentColor))
                    }
                }
                // cut markers
                for c in cuts {
                    let x = xFor(c, w: size.width)
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(line, with: .color(.red), lineWidth: 2)
                }
                // playhead
                if playhead >= 0 && playhead <= duration {
                    let x = xFor(playhead, w: size.width)
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(line, with: .color(.green), lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let x = value.location.x
                        if dragging == nil {
                            // pick up a nearby cut, else start a new-cut candidate on end
                            if let idx = nearestCut(to: x, w: w) {
                                dragging = idx
                            }
                        }
                        if let idx = dragging {
                            onMoveCut(idx, secFor(x, w: w))
                        }
                    }
                    .onEnded { value in
                        let x = value.location.x
                        if dragging == nil {
                            // a tap: near an existing cut removes it, else adds one
                            if let idx = nearestCut(to: x, w: w) {
                                onRemoveCut(idx)
                            } else {
                                onAddCut(secFor(x, w: w))
                            }
                        }
                        dragging = nil
                    }
            )
            .frame(width: w, height: h)
        }
    }

    private func xFor(_ sec: Double, w: CGFloat) -> CGFloat {
        duration > 0 ? CGFloat(sec / duration) * w : 0
    }
    private func secFor(_ x: CGFloat, w: CGFloat) -> Double {
        w > 0 ? Double(x / w) * duration : 0
    }
    private func nearestCut(to x: CGFloat, w: CGFloat) -> Int? {
        var best: Int?
        var bestDist: CGFloat = 7
        for (i, c) in cuts.enumerated() {
            let d = abs(xFor(c, w: w) - x)
            if d < bestDist { bestDist = d; best = i }
        }
        return best
    }
}
