// Performance overlay (Steam-Deck style, opt-in). Compiled into BOTH
// targets: the iOS receiver shows it over the stream, and the Mac app's
// receiver-mode video window reuses it unchanged. Pure SwiftUI — keep it
// UIKit/AppKit-free. The numbers come from PerfStats (StreamReceiver).

import SwiftUI

// MARK: - Performance overlay (Steam-Deck style, opt-in via Settings)

struct PerfOverlay: View {
    let stats: PerfStats
    let videoSize: CGSize

    var body: some View {
        VStack(spacing: 8) {
            // Metrics wrap onto extra rows when the width doesn't fit —
            // portrait iPhone is ~390pt, far less than one full row.
            FlowLayout(hSpacing: 14, vSpacing: 8) {
                // Transport badge — the question "is this cable or WiFi?"
                Text(stats.transport)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(stats.transport == "USB" ? Color.green.opacity(0.35)
                                : stats.transport == "WiFi" ? Color.blue.opacity(0.4)
                                : Color.gray.opacity(0.3),
                                in: Capsule())
                    .foregroundStyle(.white)

                if stats.e2eP50 > 0 {
                    metric("latency", String(format: "%.0f ms", stats.e2eP50))
                    metric("p95", String(format: "%.0f ms", stats.e2eP95))
                    metric("encode", String(format: "%.0f ms", stats.encodeP50))
                }
                if stats.decodeP50 > 0 {
                    metric("decode", String(format: "%.1f ms", stats.decodeP50))
                }
                if stats.photonP50 > 0 {
                    // True capture→glass latency (Metal presented handler) —
                    // the only number that includes display vsync.
                    metric("photon", String(format: "%.0f ms", stats.photonP50))
                }
                if stats.inputP50 > 0 {
                    // touch→CGEvent on the Mac; full touch-to-photon adds
                    // the render+capture wait and one e2e on top.
                    metric("input", String(format: "%.0f ms", stats.inputP50))
                }
                metric("rtt", String(format: "%.0f ms", stats.rttMs))
                metric("FPS", "\(stats.fps)")
                if stats.capFps > 0 {
                    metric("Mac cap", "\(stats.capFps)")
                }
                metric("Mbit/s", String(format: "%.1f", stats.mbps))
                metric("stalls", "\(stats.stalls)")
                metric("drops", "\(stats.macDrops)")
                if stats.macPending > 0 {
                    metric("queue", "\(stats.macPending)")
                }
                if stats.decodeFlushes > 0 {
                    metric("flushes", "\(stats.decodeFlushes)")
                }
                metric("res", "\(Int(videoSize.width))×\(Int(videoSize.height))")
            }
            // Two graphs side by side where they fit (landscape), stacked
            // where they don't (portrait).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { graphs }
                VStack(spacing: 8) { graphs }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var graphs: some View {
        graph("latency ms (cap→display)",
              BarGraph(samples: stats.e2eSamples, ceiling: 80,
                       good: 25, warn: 40, reference: nil))
        graph("frame interval ms",
              BarGraph(samples: stats.samples, ceiling: 60,
                       good: 25, warn: 50, reference: 16.7))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private func graph(_ label: String, _ content: BarGraph) -> some View {
        VStack(spacing: 2) {
            content.frame(width: 220, height: 38)
            Text(label)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}

/// Left-aligned wrapping row: children flow onto as many rows as the
/// proposed width requires. Keeps the perf overlay inside the screen in
/// portrait instead of clipping off both edges.
struct FlowLayout: Layout {
    var hSpacing: CGFloat = 14
    var vSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0
        var rowHeight: CGFloat = 0, width: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + vSpacing
                rowHeight = 0
            }
            x += size.width + hSpacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - hSpacing)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + vSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + hSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Bar graph over a rolling sample window with green/yellow/red thresholds
/// and an optional reference line (e.g. 16.7 ms = 60 fps).
struct BarGraph: View {
    let samples: [Double]
    let ceiling: Double
    let good: Double
    let warn: Double
    let reference: Double?

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty else { return }
            let barWidth = size.width / CGFloat(max(samples.count, 1))
            for (i, ms) in samples.enumerated() {
                let h = min(ms / ceiling, 1.0) * size.height
                let rect = CGRect(x: CGFloat(i) * barWidth,
                                  y: size.height - h,
                                  width: max(barWidth - 0.5, 0.5),
                                  height: h)
                let color: Color = ms <= good ? .green : ms <= warn ? .yellow : .red
                context.fill(Path(rect), with: .color(color.opacity(0.85)))
            }
            if let reference {
                let y = size.height - (reference / ceiling) * size.height
                context.stroke(Path { p in
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                }, with: .color(.white.opacity(0.35)), lineWidth: 0.5)
            }
        }
    }
}

