import Foundation
import Darwin

/// Drives the sampling loop and hands the result to the UI.
///
/// All mutable state — prev-counter values, ring buffers, the active timer —
/// lives behind a single serial `DispatchQueue`. The only cross-thread
/// transfer is an immutable `MetricsSnapshot` value, set on the main-actor
/// `MetricsStore` exactly once per tick. No shared mutable buffer.
///
/// Two tiers:
///   • Idle tier  — bar glyph only: overall CPU + memory. Runs while the
///                  panel is closed.
///   • Open tier  — everything: overall + per-core CPU, memory, processes,
///                  network, disk. Runs while the panel is visible.
/// Exactly one tier is active at a time. Switching tiers re-baselines the
/// counters that didn't exist in the previous tier so the first visible
/// reading after a switch is never a cross-gap spike.
///
/// Marked `@unchecked Sendable` because serial-queue isolation can't be
/// expressed in the type system. Invariant: never call private methods
/// directly — always go through `queue.async`.
public final class SamplingCoordinator: @unchecked Sendable {

    // MARK: - Inputs

    private weak var store: MetricsStore?
    private let cpuSampler  = CPUSampler()
    private let memSampler  = MemorySampler()
    private let netSampler  = NetworkSampler()
    private let diskSampler = DiskSampler()
    private let procSampler = ProcessSampler()

    // MARK: - Serial-queue-isolated state

    private let queue = DispatchQueue(label: "sys-monitor.sampling", qos: .utility)
    private enum Tier { case idle, open }
    private var activeTier: Tier = .idle
    private var idleTimer: DispatchSourceTimer?
    private var openTimer: DispatchSourceTimer?

    private var idleCadenceSeconds: Double
    private var openCadenceSeconds: Double
    private let gapMultiplier: Double = 2.0

    /// Whether the idle tier should also sample NET / DISK. Wired up to
    /// "is this metric in the bar?" so we don't pay for samplers nothing
    /// is rendering. Process enumeration is NEVER promoted to idle tier
    /// regardless — too expensive.
    private var idleSamplesNet: Bool = false
    private var idleSamplesDisk: Bool = false

    // Rate-metric prev state. Each one is "the last raw reading we saw,"
    // or nil if we haven't taken a baseline yet (or just dropped one due
    // to a gap or a tier switch into a tier where this metric exists).
    private var prevCpu: CPUCounters?
    private var prevPerCore: [CPUTicks]?
    private var prevNet: NetCounters?
    private var prevDisk: DiskCounters?
    private var prevProcCpu: [Int32: UInt64] = [:]
    private var prevTickTime: TimeInterval = 0

    private var generation: UInt64 = 0
    private var cpuHistory = RingBuffer(windowSeconds: 60)
    private var memHistory = RingBuffer(windowSeconds: 60)

    // MARK: - Init / lifecycle

    public init(
        store: MetricsStore,
        idleCadenceSeconds: Double = 2.0,
        openCadenceSeconds: Double = 1.0
    ) {
        self.store = store
        self.idleCadenceSeconds = idleCadenceSeconds
        self.openCadenceSeconds = openCadenceSeconds
    }

    /// Start the sampler in idle tier. Idempotent.
    public func startIdleTier() {
        queue.async { [weak self] in
            self?.transitionToIdle()
        }
    }

    /// Switch into open tier (panel is visible). Idempotent — calling while
    /// already open is a no-op so flap-clicks don't restart the timer.
    public func enterOpenTier() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.activeTier == .open { return }
            self.transitionToOpen()
        }
    }

    /// Switch back to idle tier (panel was dismissed). Idempotent.
    public func enterIdleTier() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.activeTier == .idle { return }
            self.transitionToIdle()
        }
    }

    /// Treat the next tick as a fresh baseline — every rate metric drops to
    /// `.measuring` for one tick, no cross-gap delta is computed. Called on
    /// wake from sleep.
    public func reBaseline() {
        queue.async { [weak self] in
            self?.dropAllBaselines()
        }
    }

    /// Settings changed the idle cadence. If we're currently in idle tier,
    /// re-schedule the timer to the new value (which also re-baselines —
    /// the glyph blinks "—" once then resumes). If we're in open tier, the
    /// new cadence takes effect on the next tier-return.
    public func updateIdleCadenceSeconds(_ seconds: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            self.idleCadenceSeconds = seconds
            if self.activeTier == .idle { self.transitionToIdle() }
        }
    }

    /// Settings changed the open cadence. If we're currently in open tier,
    /// re-schedule + re-baseline. Otherwise the new value takes effect on
    /// the next panel open.
    public func updateOpenCadenceSeconds(_ seconds: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            self.openCadenceSeconds = seconds
            if self.activeTier == .open { self.transitionToOpen() }
        }
    }

    /// Tell the coordinator which idle-tier samplers to run. Mirror of
    /// "is NET / DISK shown in the bar?" — turning a sampler off drops
    /// its prev baseline so the next time it's needed it re-baselines
    /// rather than computing across an arbitrary stale gap.
    public func configureIdleSamplers(net: Bool, disk: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.idleSamplesNet = net
            self.idleSamplesDisk = disk
            if !net  { self.prevNet  = nil }
            if !disk { self.prevDisk = nil }
        }
    }

    /// Stop everything cleanly. Called from `applicationWillTerminate`.
    public func shutdown() {
        queue.async { [weak self] in
            self?.idleTimer?.cancel()
            self?.openTimer?.cancel()
            self?.idleTimer = nil
            self?.openTimer = nil
        }
    }

    // MARK: - Tier transitions (run only on `queue`)

    private func transitionToIdle() {
        openTimer?.cancel()
        openTimer = nil
        // Per-core and process state are open-tier only — drop them so a
        // stale value never gets reused. NET/DISK prevs ARE preserved:
        // if the user keeps those in the bar, the idle tier also samples
        // them, so the rate keeps computing across the transition. The
        // gap-based re-baseline in readNet/readDisk handles the case
        // where idle doesn't sample them (stale prev is detected by
        // elapsed > N×tick).
        prevPerCore = nil
        prevProcCpu.removeAll(keepingCapacity: true)

        startTimer(
            cadence: idleCadenceSeconds,
            assignTo: { [weak self] t in self?.idleTimer = t },
            handler: { [weak self] in self?.idleTick() }
        )
        activeTier = .idle
    }

    private func transitionToOpen() {
        idleTimer?.cancel()
        idleTimer = nil
        // Per-core/process are open-tier only and need fresh baselines.
        // NET/DISK prevs survive — if idle tier was sampling them, they
        // are fresh and the next open tick can emit a rate immediately.
        // If idle wasn't sampling them, the gap-based re-baseline
        // triggers automatically.
        prevPerCore = nil
        prevProcCpu.removeAll(keepingCapacity: true)

        startTimer(
            cadence: openCadenceSeconds,
            assignTo: { [weak self] t in self?.openTimer = t },
            handler: { [weak self] in self?.openTick() }
        )
        activeTier = .open
    }

    private func startTimer(
        cadence: Double,
        assignTo: (DispatchSourceTimer) -> Void,
        handler: @escaping () -> Void
    ) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(
            deadline: .now() + .milliseconds(20),
            repeating: .milliseconds(Int(cadence * 1000.0)),
            leeway: .milliseconds(50)
        )
        t.setEventHandler(handler: handler)
        t.resume()
        assignTo(t)
    }

    private func dropAllBaselines() {
        prevCpu = nil
        prevPerCore = nil
        prevNet = nil
        prevDisk = nil
        prevProcCpu.removeAll(keepingCapacity: true)
        prevTickTime = 0
    }

    // MARK: - Ticks

    /// Idle tier: overall CPU + memory always; NET / DISK only if a
    /// corresponding bar cell asked for them. Process enumeration is
    /// never in idle tier.
    private func idleTick() {
        let now = monoSeconds()
        let elapsed = (prevTickTime > 0) ? (now - prevTickTime) : 0
        let isGap = (elapsed <= 0) || (elapsed > idleCadenceSeconds * gapMultiplier)

        let cpuMetric  = readOverallCPU(now: now, isGap: isGap)
        let memMetric  = readMemory(now: now)
        let netMetric: Metric<Throughput> = idleSamplesNet
            ? readNet(now: now, elapsed: elapsed, isGap: isGap)
            : .measuring
        let diskMetric: Metric<Throughput> = idleSamplesDisk
            ? readDisk(now: now, elapsed: elapsed, isGap: isGap)
            : .measuring

        prevTickTime = now
        publishSnapshot(
            cpu: cpuMetric,
            memory: memMetric,
            processes: .measuring,
            net: netMetric,
            disk: diskMetric
        )
    }

    /// Open tier: full sweep — overall + per-core CPU, memory, processes,
    /// network, disk. Process enumeration is the expensive operation and
    /// runs ONLY here.
    private func openTick() {
        let now = monoSeconds()
        let elapsed = (prevTickTime > 0) ? (now - prevTickTime) : 0
        let isGap = (elapsed <= 0) || (elapsed > openCadenceSeconds * gapMultiplier)

        let cpuMetric  = readFullCPU(now: now, isGap: isGap)
        let memMetric  = readMemory(now: now)
        let netMetric  = readNet(now: now, elapsed: elapsed, isGap: isGap)
        let diskMetric = readDisk(now: now, elapsed: elapsed, isGap: isGap)
        let procMetric = readProcesses(now: now, elapsed: elapsed, isGap: isGap)

        prevTickTime = now
        publishSnapshot(
            cpu: cpuMetric,
            memory: memMetric,
            processes: procMetric,
            net: netMetric,
            disk: diskMetric
        )
    }

    // MARK: - Per-metric reads (run only on `queue`)

    private func readOverallCPU(now: TimeInterval, isGap: Bool) -> Metric<CPUSample> {
        let counters: CPUCounters
        do { counters = try cpuSampler.read() } catch { return .unavailable }
        defer { prevCpu = counters }

        guard let prev = prevCpu, !isGap else { return .measuring }
        let overall = RateMath.cpuUtilization(prev: prev.overall, now: counters.overall)
        cpuHistory.append(HistoryPoint(timestamp: now, value: overall))
        return .ok(CPUSample(overall: overall, perCore: []))
    }

    private func readFullCPU(now: TimeInterval, isGap: Bool) -> Metric<CPUSample> {
        let counters: CPUCounters
        do { counters = try cpuSampler.read() } catch { return .unavailable }
        defer {
            prevCpu = counters
            prevPerCore = counters.perCore
        }

        guard let prev = prevCpu, !isGap else { return .measuring }
        let overall = RateMath.cpuUtilization(prev: prev.overall, now: counters.overall)
        cpuHistory.append(HistoryPoint(timestamp: now, value: overall))

        // Per-core needs its own prev because we may have just entered the
        // open tier and the idle tier never collected per-core readings.
        let perCore: [Double]
        if let pp = prevPerCore, pp.count == counters.perCore.count {
            perCore = RateMath.cpuPerCore(prev: pp, now: counters.perCore)
        } else {
            perCore = []  // first open tick — show the strip empty until the next tick
        }
        return .ok(CPUSample(overall: overall, perCore: perCore))
    }

    private func readMemory(now: TimeInterval) -> Metric<MemorySample> {
        do {
            let raw = try memSampler.read()
            if raw.physicalTotalBytes > 0 {
                let frac = Double(raw.usedBytes) / Double(raw.physicalTotalBytes)
                memHistory.append(HistoryPoint(timestamp: now, value: frac))
            }
            return .ok(raw.toSample())
        } catch {
            return .unavailable
        }
    }

    private func readNet(
        now: TimeInterval, elapsed: TimeInterval, isGap: Bool
    ) -> Metric<Throughput> {
        let counters: NetCounters
        do { counters = try netSampler.read() } catch { return .unavailable }
        defer { prevNet = counters }

        guard let prev = prevNet, !isGap else { return .measuring }
        // Interface set changed (VPN flip, USB plug) → treat as gap.
        if prev.ifaceSet != counters.ifaceSet { return .measuring }
        guard
            let inBps  = RateMath.bytesPerSec(prev: prev.inBytes,  now: counters.inBytes,  elapsed: elapsed),
            let outBps = RateMath.bytesPerSec(prev: prev.outBytes, now: counters.outBytes, elapsed: elapsed)
        else { return .measuring }
        return .ok(Throughput(inPerSec: inBps, outPerSec: outBps))
    }

    private func readDisk(
        now: TimeInterval, elapsed: TimeInterval, isGap: Bool
    ) -> Metric<Throughput> {
        let counters: DiskCounters
        do { counters = try diskSampler.read() } catch { return .unavailable }
        defer { prevDisk = counters }

        guard let prev = prevDisk, !isGap else { return .measuring }
        guard
            let rBps = RateMath.bytesPerSec(prev: prev.readBytes,  now: counters.readBytes,  elapsed: elapsed),
            let wBps = RateMath.bytesPerSec(prev: prev.writeBytes, now: counters.writeBytes, elapsed: elapsed)
        else { return .measuring }
        return .ok(Throughput(inPerSec: rBps, outPerSec: wBps))
    }

    private func readProcesses(
        now: TimeInterval, elapsed: TimeInterval, isGap: Bool
    ) -> Metric<[ProcSample]> {
        let raws: [ProcRaw]
        do { raws = try procSampler.read() } catch { return .unavailable }

        // Build the next prev-cpu-time map regardless, so the next tick can
        // delta even if this one returns `.measuring`.
        var nextPrev: [Int32: UInt64] = [:]
        nextPrev.reserveCapacity(raws.count)

        var samples: [ProcSample] = []
        samples.reserveCapacity(raws.count)

        // Phase guard: we need a previous reading AND a non-gap elapsed to
        // compute per-process %CPU.
        let canCompute = !isGap && elapsed > 0 && !prevProcCpu.isEmpty
        let elapsedNs = elapsed * 1_000_000_000

        for raw in raws {
            nextPrev[raw.pid] = raw.cpuTimeNs
            if canCompute, let prevNs = prevProcCpu[raw.pid], raw.cpuTimeNs >= prevNs {
                // Δns CPU-time / Δns wall-clock = fraction of one core,
                // matching Activity Monitor's convention (can exceed 1.0
                // for multi-threaded processes spanning cores).
                let cpu = Double(raw.cpuTimeNs - prevNs) / elapsedNs
                samples.append(ProcSample(
                    pid: raw.pid,
                    name: raw.name,
                    cpu: cpu,
                    memBytes: raw.residentBytes
                ))
            }
        }
        prevProcCpu = nextPrev

        if !canCompute { return .measuring }
        return .ok(samples)
    }

    // MARK: - Publish

    private func publishSnapshot(
        cpu: Metric<CPUSample>,
        memory: Metric<MemorySample>,
        processes: Metric<[ProcSample]>,
        net: Metric<Throughput>,
        disk: Metric<Throughput>
    ) {
        generation &+= 1
        let snap = MetricsSnapshot(
            generation: generation,
            cpu: cpu,
            memory: memory,
            processes: processes,
            net: net,
            disk: disk,
            cpuHistory: cpuHistory,
            memHistory: memHistory
        )
        Task { @MainActor [weak store] in
            store?.snapshot = snap
        }
    }
}

// Wall-clock seconds from a source immune to user clock changes. Same
// helper used by the probe so "elapsed" means the same thing everywhere.
@inline(__always)
func monoSeconds() -> TimeInterval {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000
}
