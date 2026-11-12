import WidgetKit
import SwiftUI

// The Notification Centre and desktop widget.
//
// macOS decides when a widget is refreshed, and allows a few dozen refreshes a
// day, so this cannot be a live meter. It carries the figures that are still
// true several minutes later: memory in use, free storage, battery and load.
// The menu-bar app remains the live instrument.
//
// The readings come from the same sampler sources the app compiles, so the
// widget and the panel cannot disagree about what "memory used" means.

/// Everything one widget refresh shows, read at `date`.
struct WidgetReading: TimelineEntry {
    let date: Date
    let memory: MemorySample?
    let storage: DiskSpaceSample?
    let battery: BatterySample?
    let load: LoadAverage?
    let cores: Int

    static func now() -> WidgetReading {
        let raw = try? MemorySampler().read()
        return WidgetReading(
            date: Date(),
            // The widget takes one reading, so it has no reclaim rate and no
            // kernel pressure level; it shows the amount, not a verdict.
            memory: raw?.toSample(pressure: .normal, reclaim: nil),
            storage: DiskSpaceSampler().read(),
            battery: BatterySampler().read(),
            load: LoadSampler().read(),
            cores: ProcessInfo.processInfo.activeProcessorCount
        )
    }
}

struct ReadingProvider: TimelineProvider {
    func placeholder(in context: Context) -> WidgetReading { .now() }

    func getSnapshot(in context: Context, completion: @escaping (WidgetReading) -> Void) {
        completion(.now())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetReading>) -> Void) {
        // Ask for a refresh in five minutes. The system treats this as the
        // earliest it may refresh, not a promise.
        let next = Date().addingTimeInterval(5 * 60)
        completion(Timeline(entries: [.now()], policy: .after(next)))
    }
}

private func gigabytes(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    return gb >= 100 ? String(format: "%.0f GB", gb) : String(format: "%.1f GB", gb)
}

/// One labelled figure with a thin fill bar under it.
private struct Gauge: View {
    let label: String
    let value: String
    let detail: String
    let fraction: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(tint)
                        .frame(width: geo.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: 4)
            Text(detail)
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SysMonitorWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let reading: WidgetReading

    private var memoryGauge: Gauge {
        guard let m = reading.memory, m.totalBytes > 0 else {
            return Gauge(label: "MEMORY", value: "No reading", detail: " ", fraction: 0, tint: .teal)
        }
        let frac = Double(m.usedBytes) / Double(m.totalBytes)
        let swap = m.swapUsedBytes > 0 ? " · swap \(gigabytes(m.swapUsedBytes))" : ""
        return Gauge(label: "MEMORY",
                     value: "\(Int((frac * 100).rounded()))%",
                     detail: "\(gigabytes(m.usedBytes)) of \(gigabytes(m.totalBytes))\(swap)",
                     fraction: frac, tint: .teal)
    }

    private var storageGauge: Gauge {
        guard let d = reading.storage, d.totalBytes > 0 else {
            return Gauge(label: "STORAGE", value: "No reading", detail: " ", fraction: 0, tint: .orange)
        }
        let used = d.totalBytes >= d.freeBytes ? d.totalBytes - d.freeBytes : 0
        return Gauge(label: "STORAGE",
                     value: "\(gigabytes(d.freeBytes)) free",
                     detail: "of \(gigabytes(d.totalBytes))",
                     fraction: Double(used) / Double(d.totalBytes), tint: .orange)
    }

    private var thirdGauge: Gauge {
        if let b = reading.battery {
            let state = b.charging ? "charging" : (b.onAC ? "on power" : "on battery")
            return Gauge(label: "BATTERY", value: "\(b.percent)%", detail: state,
                         fraction: Double(b.percent) / 100, tint: .green)
        }
        let one = reading.load?.one ?? 0
        return Gauge(label: "LOAD", value: String(format: "%.1f", one),
                     detail: "\(reading.cores) cores",
                     fraction: one / Double(max(reading.cores, 1)), tint: .blue)
    }

    var body: some View {
        Group {
            if family == .systemSmall {
                VStack(alignment: .leading, spacing: 10) {
                    memoryGauge
                    storageGauge
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    memoryGauge
                    storageGauge
                    thirdGauge
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct SysMonitorWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.sys-monitor.menubar.overview",
                            provider: ReadingProvider()) { reading in
            SysMonitorWidgetView(reading: reading)
        }
        .configurationDisplayName("System overview")
        .description("Memory in use, free storage and battery. Refreshed by macOS every few minutes.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct SysMonitorWidgets: WidgetBundle {
    var body: some Widget { SysMonitorWidget() }
}
