import Foundation

/// What the alert system watches for and when it speaks up. All values are
/// user-tunable (Settings ▸ Alerts); the defaults are deliberately quiet —
/// alerts ship OFF, and when on, fire only on a *sustained* high reading,
/// not a one-tick spike.
public struct AlertConfig: Sendable, Equatable {
    /// Master switch. Off → the evaluator is inert and holds no state.
    public var enabled: Bool
    /// CPU / memory load (0…1) at or above which the metric is "high".
    public var cpuThreshold: Double
    public var memThreshold: Double
    /// How many consecutive ticks a metric must stay high before firing —
    /// the debounce that turns a transient spike into a real condition.
    public var sustainTicks: Int
    /// After firing, stay silent for this long even if still high, so a
    /// persistent condition notifies once, not every tick.
    public var cooldownSeconds: Double

    public init(enabled: Bool, cpuThreshold: Double, memThreshold: Double,
                sustainTicks: Int, cooldownSeconds: Double) {
        self.enabled = enabled
        self.cpuThreshold = cpuThreshold
        self.memThreshold = memThreshold
        self.sustainTicks = sustainTicks
        self.cooldownSeconds = cooldownSeconds
    }

    public static let defaults = AlertConfig(
        enabled: false, cpuThreshold: 0.85, memThreshold: 0.90,
        sustainTicks: 5, cooldownSeconds: 300)
}

public enum AlertKind: String, Sendable {
    case cpu, memory
}

/// One fired alert — kind plus the human line shown in the notification.
public struct AlertEvent: Sendable, Equatable {
    public let kind: AlertKind
    public let title: String
    public let body: String
}

/// The alert decision core, as a pure value type: feed it one reading per
/// tick and it returns the alerts to post *right now* (usually none). It
/// owns no I/O and reads no clock — `now` is passed in — so the whole
/// debounce-and-cooldown behavior is exercisable in `--self-test`.
///
/// Per-metric it tracks a streak of consecutive high ticks and the time it
/// last fired. A metric fires when its streak reaches `sustainTicks` and it
/// is past its cooldown; dropping below the threshold (or going
/// unavailable) resets the streak.
public struct AlertEvaluator: Sendable {
    public var config: AlertConfig

    private var cpuStreak = 0
    private var memStreak = 0
    private var cpuLastFired: Double?
    private var memLastFired: Double?

    public init(config: AlertConfig) { self.config = config }

    /// `cpuLoad` / `memLoad` are nil when that metric is unavailable this
    /// tick (which resets its streak — we don't alert on missing data).
    /// `now` is monotonic seconds. Returns the events to post this tick.
    public mutating func evaluate(cpuLoad: Double?, memLoad: Double?, now: Double) -> [AlertEvent] {
        guard config.enabled else {
            cpuStreak = 0; memStreak = 0
            return []
        }
        // Copy thresholds into locals first so the static stepper takes
        // only value params — passing `&cpuStreak` into a method on `self`
        // would overlap `self`'s exclusive access.
        var events: [AlertEvent] = []
        if let e = Self.step(load: cpuLoad, threshold: config.cpuThreshold,
                             sustainTicks: config.sustainTicks, cooldown: config.cooldownSeconds,
                             streak: &cpuStreak, lastFired: &cpuLastFired, now: now, kind: .cpu) {
            events.append(e)
        }
        if let e = Self.step(load: memLoad, threshold: config.memThreshold,
                             sustainTicks: config.sustainTicks, cooldown: config.cooldownSeconds,
                             streak: &memStreak, lastFired: &memLastFired, now: now, kind: .memory) {
            events.append(e)
        }
        return events
    }

    private static func step(load: Double?, threshold: Double,
                             sustainTicks: Int, cooldown: Double,
                             streak: inout Int, lastFired: inout Double?,
                             now: Double, kind: AlertKind) -> AlertEvent? {
        guard let load else { streak = 0; return nil }   // unavailable → reset
        guard load >= threshold else { streak = 0; return nil }

        streak += 1
        guard streak >= sustainTicks else { return nil }

        // Sustained. Fire unless still cooling down from the last one.
        if let last = lastFired, now - last < cooldown { return nil }
        lastFired = now
        streak = 0   // re-count from scratch toward the next possible fire

        let pct = Int((load * 100).rounded())
        switch kind {
        case .cpu:
            return AlertEvent(kind: .cpu, title: "High CPU",
                              body: "CPU has been at \(pct)% for a while.")
        case .memory:
            return AlertEvent(kind: .memory, title: "High memory",
                              body: "Memory has been at \(pct)% for a while.")
        }
    }
}
