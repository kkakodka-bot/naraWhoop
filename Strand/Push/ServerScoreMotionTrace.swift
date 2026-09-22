import SwiftUI
import StrandDesign

/// The existing sleep movement strip, retaining the server's absolute epoch positions and holes.
struct ServerScoreMotionTrace: View {
    let runs: [[ServerScoreMotionPoint]]
    let start: Int
    let end: Int

    var body: some View {
        GeometryReader { geometry in
            let peak = runs.flatMap { $0 }.map(\.value).max() ?? 0
            let span = Double(max(1, end - start))
            let height = geometry.size.height
            ZStack {
                ForEach(runs.indices, id: \.self) { index in
                    let points = runs[index].map { point in
                        CGPoint(x: Double(point.timestamp - Int64(start)) / span * geometry.size.width,
                                y: height - (peak > 0 ? point.value / peak : 0) * (height - 2))
                    }
                    Path { path in
                        guard let first = points.first, let last = points.last else { return }
                        path.move(to: CGPoint(x: first.x, y: height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: last.x, y: height))
                        path.closeSubpath()
                    }.fill(StrandPalette.restColor.opacity(0.22))
                    Path { path in
                        guard let first = points.first else { return }
                        if points.count == 1 {
                            path.move(to: CGPoint(x: first.x, y: height)); path.addLine(to: first)
                        } else {
                            path.move(to: first); points.dropFirst().forEach { path.addLine(to: $0) }
                        }
                    }.stroke(StrandPalette.restColor.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Movement during sleep")
        }.frame(height: 40)
    }
}
