import SwiftUI

/// A small line of recent values. A `Path`, not Swift Charts: nothing to load
/// for a few dozen points.
struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { proxy in
            let peak = max(values.max() ?? 0, 0.001)
            let step = values.count > 1 ? proxy.size.width / CGFloat(values.count - 1) : 0
            let point = { (i: Int) in
                CGPoint(x: CGFloat(i) * step, y: proxy.size.height * (1 - CGFloat(values[i] / peak)))
            }
            Path { path in
                guard !values.isEmpty else { return }
                path.move(to: point(0))
                for i in values.indices.dropFirst() { path.addLine(to: point(i)) }
            }
            .stroke(.tint, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }
    }
}
