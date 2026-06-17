import Foundation
import os

/// Apple-Silicon package power (CPU / GPU / ANE) in watts, from the
/// PRIVATE IOReport energy counters — the sudoless mechanism macmon and
/// socpowerbud use. Held to the same adapter contract as the other two
/// private-framework readers in this app: every symbol resolved at
/// runtime, ANY failure degrades the whole monitor to "unavailable"
/// without touching the rest of the app, no root, no entitlement.
///
/// IOReport exposes cumulative ENERGY counters; power is Δenergy ÷ Δtime.
/// The monitor keeps the previous full sample and diffs each new one
/// against it (the standard dual-sample pattern), so the first `read()`
/// after a (re)start returns nil while it establishes a baseline.
///
/// Channel naming drifts across chip generations: the "Energy Model"
/// group exposes both physical per-cluster channels (MCPU0_x, PACC_x,
/// PCPUDTL…) AND friendly aggregates (CPU Energy, GPU Energy, ANE). We
/// match only the friendly aggregates by name suffix/equality so the
/// physical breakdown never double-counts. Verified on this machine via
/// the probe at .claude/output/20260615-ioreport-probe/.
final class PowerMonitor: @unchecked Sendable {

    private(set) var isAvailable = false

    private let queue = DispatchQueue(label: "sys-monitor.power")
    private let log = Logger(subsystem: "dev.sys-monitor.menubar", category: "power")

    private typealias CopyAllT = @convention(c) (UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubT = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> Unmanaged<AnyObject>?
    private typealias CreateSamplesT = @convention(c) (AnyObject, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateDeltaT = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias ChStrT = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias SimpleIntT = @convention(c) (CFDictionary, Int32) -> Int64

    private var createSamples: CreateSamplesT?
    private var createDelta: CreateDeltaT?
    private var getGroup: ChStrT?
    private var getName: ChStrT?
    private var getUnit: ChStrT?
    private var simpleInt: SimpleIntT?

    private var channels: CFMutableDictionary?
    private var subscription: AnyObject?

    private var prevSample: CFDictionary?
    private var prevTime: TimeInterval = 0

    init() {
        queue.sync { self.setup() }
    }

    /// Reset the baseline so the next `read()` re-establishes it. Called
    /// when the consumer (panel) re-opens after being closed for a while.
    func resetBaseline() {
        queue.async { [weak self] in
            self?.prevSample = nil
            self?.prevTime = 0
        }
    }

    /// Take a fresh IOReport sample, diff against the previous one, and
    /// return package power in watts. nil until a baseline exists or when
    /// unavailable. `now` is the caller's monotonic clock.
    func read(now: TimeInterval) -> PowerSample? {
        queue.sync {
            guard isAvailable,
                  let channels, let sub = subscription,
                  let createSamples, let createDelta else { return nil }

            guard let curU = createSamples(sub, channels, nil) else { return nil }
            let cur = curU.takeRetainedValue()
            defer { prevSample = cur; prevTime = now }

            guard let prev = prevSample, prevTime > 0, now > prevTime,
                  let deltaU = createDelta(prev, cur, nil) else { return nil }
            let dt = now - prevTime
            let delta = deltaU.takeRetainedValue()
            return power(from: delta, dt: dt)
        }
    }

    // MARK: - Setup (runs once, on `queue`)

    private func setup() {
        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else {
            log.info("power unavailable: dlopen libIOReport failed")
            return
        }
        func fn<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard
            let copyAll = fn("IOReportCopyAllChannels", CopyAllT.self),
            let createSub = fn("IOReportCreateSubscription", CreateSubT.self),
            let cs = fn("IOReportCreateSamples", CreateSamplesT.self),
            let cd = fn("IOReportCreateSamplesDelta", CreateDeltaT.self),
            let gg = fn("IOReportChannelGetGroup", ChStrT.self),
            let gn = fn("IOReportChannelGetChannelName", ChStrT.self),
            let gu = fn("IOReportChannelGetUnitLabel", ChStrT.self),
            let si = fn("IOReportSimpleGetIntegerValue", SimpleIntT.self)
        else {
            log.info("power unavailable: IOReport symbol resolution failed")
            return
        }
        guard let chanU = copyAll(0, 0) else {
            log.info("power unavailable: CopyAllChannels nil")
            return
        }
        let chan = chanU.takeRetainedValue()
        var subbed: Unmanaged<CFMutableDictionary>? = nil
        guard let subU = createSub(nil, chan, &subbed, 0, nil) else {
            log.info("power unavailable: CreateSubscription nil")
            return
        }
        self.createSamples = cs
        self.createDelta = cd
        self.getGroup = gg; self.getName = gn; self.getUnit = gu; self.simpleInt = si
        self.channels = chan
        self.subscription = subU.takeRetainedValue()
        self.isAvailable = true
        log.info("power available — IOReport energy counters online")
    }

    // MARK: - Delta walk

    private func power(from delta: CFDictionary, dt: Double) -> PowerSample? {
        guard let getGroup, let getName, let getUnit, let simpleInt,
              let d = delta as? [String: Any],
              let chans = d["IOReportChannels"] as? [Any] else { return nil }

        var cpu = 0.0, gpu = 0.0, ane = 0.0
        for c in chans {
            // Guarded, not force-cast: a future macOS could change the
            // channel element type. `as? NSDictionary` is a real runtime
            // check (nil for a non-dict); the bridge to CFDictionary is
            // toll-free. Skip a malformed entry rather than trap the whole
            // sampler (the adapter already degrades to unavailable if the
            // symbols don't resolve; this guards the per-element walk).
            guard let nd = c as? NSDictionary else { continue }
            let cd = nd as CFDictionary
            guard (getGroup(cd)?.takeUnretainedValue() as String?) == "Energy Model" else { continue }
            let name = getName(cd)?.takeUnretainedValue() as String? ?? ""
            let unit = getUnit(cd)?.takeUnretainedValue() as String? ?? ""
            guard let div = Self.unitDivisor(unit) else { continue }
            let watts = Double(simpleInt(cd, 0)) / div / dt
            // Friendly aggregates only — the physical per-cluster channels
            // (MCPU…, PACC…, PCPUDTL…) would double-count.
            if name.hasSuffix("CPU Energy") { cpu += watts }
            else if name == "GPU Energy" { gpu += watts }
            else if name == "ANE Energy" || name == "ANE" { ane += watts }
        }
        return PowerSample(cpuWatts: cpu, gpuWatts: gpu, aneWatts: ane)
    }

    /// Joules-per-unit divisor for the channel's energy unit label.
    private static func unitDivisor(_ u: String) -> Double? {
        switch u.trimmingCharacters(in: .whitespaces).lowercased() {
        case "mj":         return 1e3
        case "uj", "µj":   return 1e6
        case "nj":         return 1e9
        default:           return nil
        }
    }
}
