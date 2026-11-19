import SwiftUI
import Charts

/// Live stacked memory chart built from real `host_statistics64` samples, with ON/OFF markers.
struct MemoryChartView: View {
    @ObservedObject var monitor: MemoryMonitor
    @State private var window: TimeInterval = 300

    private struct Point: Identifiable {
        var id: String { "\(category)-\(date.timeIntervalSince1970)" }
        var date: Date
        var category: String
        var gb: Double
    }

    private var points: [Point] {
        let cutoff = Date().addingTimeInterval(-window)
        let samples = monitor.history.filter { $0.timestamp >= cutoff }
        // Downsample to ≤ 240 points per series to keep rendering cheap.
        let stride = max(1, samples.count / 240)
        return samples.enumerated().filter { $0.offset % stride == 0 }.flatMap { _, s -> [Point] in
            [
                Point(date: s.timestamp, category: "Wired", gb: gb(s.wiredBytes)),
                Point(date: s.timestamp, category: "App", gb: gb(s.appBytes)),
                Point(date: s.timestamp, category: "Compressed", gb: gb(s.compressedBytes)),
                Point(date: s.timestamp, category: "Cached", gb: gb(s.cachedBytes)),
            ]
        }
    }

    private func gb(_ b: UInt64) -> Double { Double(b) / 1_073_741_824 }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Memory").font(.headline)
                    Spacer()
                    Picker("Range", selection: $window) {
                        Text("1 min").tag(TimeInterval(60))
                        Text("5 min").tag(TimeInterval(300))
                        Text("30 min").tag(TimeInterval(1800))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                }
                Chart {
                    ForEach(points) { p in
                        AreaMark(x: .value("Time", p.date), y: .value("GB", p.gb))
                            .foregroundStyle(by: .value("Type", p.category))
                            .interpolationMethod(.monotone)
                    }
                    if let total = monitor.latest?.totalBytes {
                        RuleMark(y: .value("Total", gb(total)))
                            .foregroundStyle(.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .annotation(position: .top, alignment: .leading) {
                                Text("Total \(ByteFormat.string(total))").font(.caption2).foregroundStyle(.secondary)
                            }
                    }
                    ForEach(monitor.markers.filter { $0.date >= Date().addingTimeInterval(-window) }) { m in
                        RuleMark(x: .value("Event", m.date))
                            .foregroundStyle(.purple)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .annotation(position: .top, alignment: .trailing) {
                                Text(m.label).font(.caption2.weight(.semibold)).foregroundStyle(.purple)
                            }
                    }
                }
                .chartForegroundStyleScale([
                    "Wired": Color.orange, "App": Color.blue, "Compressed": Color.pink, "Cached": Color.gray.opacity(0.5),
                ])
                .chartYAxisLabel("GB")
                .frame(height: 190)
                Text("Wired, App and Compressed make up memory in use. Cached files are reclaimable instantly by macOS.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Before/after comparison captured at activation time.
struct BeforeAfterView: View {
    var before: MemorySample?
    var after: MemorySample?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Effect of AI Mode").font(.headline)
                if let before {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        GridRow {
                            Text("").gridColumnAlignment(.leading)
                            Text("Before").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text("After").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text("Change").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        row("Available", before.availableBytes, after?.availableBytes, higherIsBetter: true)
                        row("App memory", before.appBytes, after?.appBytes, higherIsBetter: false)
                        row("Compressed", before.compressedBytes, after?.compressedBytes, higherIsBetter: false)
                        row("Swap used", before.swapUsedBytes, after?.swapUsedBytes, higherIsBetter: false)
                    }
                    .font(.callout.monospacedDigit())
                    if after == nil {
                        Text("“After” is measured a few seconds after activation finishes (it includes the loaded model).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Enable AI Mode to record a before/after measurement.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ b: UInt64, _ a: UInt64?, higherIsBetter: Bool) -> some View {
        GridRow {
            Text(label)
            Text(ByteFormat.string(b))
            Text(a.map(ByteFormat.string) ?? "—")
            if let a {
                let delta = Int64(bitPattern: a) - Int64(bitPattern: b)
                let good = higherIsBetter ? delta >= 0 : delta <= 0
                Text(ByteFormat.signed(delta)).foregroundStyle(delta == 0 ? Color.secondary : (good ? Color.green : Color.orange))
            } else {
                Text("—")
            }
        }
    }
}
