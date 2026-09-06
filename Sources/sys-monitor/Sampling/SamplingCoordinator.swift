import Foundation
import Darwin
import os

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
    private let netMonitor = PerProcessNetworkMonitor()
    private let powerMonitor = PowerMonitor()
    private let batterySampler = BatterySampler()
    private let diskSpaceSampler = DiskSpaceSampler()
    private let loadSampler = LoadSampler()
    /// Per-interface NET rates from the last successful net read — additive
    /// to the aggregate (which keeps its own field-bug-fixed rate path).
    private var lastPerInterfaceNet: [InterfaceThroughput] = []

    // MARK: - Serial-queue-isolated state

    private let queue = DispatchQueue(label: "sys-monitor.sampling", qos: .utility)
    private enum Tier { case idle, open }
    private var activeTier: Tier = .idle
    /// The tier the shell *asked for*, recorded even while transitions are
    /// refused during display suspension. Resume restores this — not the
    /// last achieved tier — so a panel opened while the display was dark
    /// gets its open tier when the lights come back.
    private var desiredTier: Tier = .idle
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

    /// Alert decision state — mutated only on `queue` (every tick feeds it
    /// one reading). Disabled by default; the shell pushes the user's
    /// config via `updateAlertConfig`. `onAlert` is invoked on the main
    /// actor for each fired alert (notification posting is UI work).
    private var alertEvaluator = AlertEvaluator(config: .defaults)
    private var onAlert: (@MainActor @Sendable ([AlertEvent]) -> Void)?
    /// The user's severity thresholds, pushed in the same way the alert config
    /// is. The alert gate needs the same CPU gate the colours use, or the
    /// notification and the menu bar disagree about the same machine.
    private var currentThresholds: SeverityThresholds = .defaults

    // Rate-metric prev state. Each one is "the last raw reading we saw,"
    // or nil if we haven't taken a baseline yet (or just dropped one due
    // to a gap or a tier switch into a tier where this metric exists).
    private var prevOverall: CPUTicks?
    private var prevPerCore: [CPUTicks]?
    private var prevNet: NetCounters?
    private var prevDisk: DiskCounters?
    private var prevProcCpu: [Int32: UInt64] = [:]
    private var prevProcDisk: [Int32: UInt64] = [:]
    private var prevProcNet: [Int32: UInt64] = [:]
    private var prevProcEnergy: [Int32: UInt64] = [:]
    private var prevTickTime: TimeInterval = 0
    /// Cadence that was in force when `prevTickTime` was stamped. The gap
    /// test must judge the elapsed interval against the cadence it was
    /// ACCUMULATED under — the first tick after a tier switch or cadence
    /// change otherwise tests a 5 s idle interval against a 1 s open
    /// threshold and wipes every healthy rate to "measuring" (field bugs
    /// FB-2 / FB-4).
    private var prevTickCadence: Double = 0

    /// NET and DISK keep their own last-read clocks, because they are not
    /// read on every tick: the idle tier samples them only when a bar cell
    /// asks for them. `prevTickTime` advances on every tick regardless, so
    /// deriving their elapsed from it divided a whole panel-closed period of
    /// bytes by one tick's worth of time — a 10 GB/s disk row on reopen, and
    /// a 1.00 spike parked in the sparkline for the rest of the window. The
    /// shared gap test could not see it, because the interval it judged was
    /// healthy; the stale thing was the counter, not the clock.
    private var netClock = RateMath.SampleClock()
    private var diskClock = RateMath.SampleClock()
    /// Memory is read every tick in both tiers, so its clock never diverges
    /// from the tick the way NET and DISK do. It owns one anyway, because the
    /// reclaim counters are cumulative and the rule from `0090c05` is that a
    /// rate divides by ITS metric's elapsed time, not by whatever tick fired.
    private var memClock = RateMath.SampleClock()
    private var prevMemRaw: MemoryRaw?

    // Process enumeration runs every 2nd open tick (it's the open tier's
    // dominant cost, and a 2 s %CPU window is less noisy than 1 s anyway).
    // Its rate math therefore needs its own elapsed clock — deltaing a
    // 2-tick cpu-time difference over 1 tick's elapsed would double every
    // value — and its own cached metric so skipped ticks re-publish the
    // last list instead of flashing "measuring".
    private var openTickIndex: UInt64 = 0
    private var lastProcSampleTime: TimeInterval = 0
    private var lastProcMetric: Metric<[ProcSample]> = .measuring
    /// Increments on every open-tier entry. The +300 ms early tick
    /// captures it at schedule time and aborts on mismatch, so an early
    /// tick scheduled by one open session can never fire into a later
    /// one (close→reopen within the delay window).
    private var openEpoch: UInt64 = 0

    /// True while the display is asleep / screen locked — both timers are
    /// cancelled and tier transitions are refused until resume.
    private var displaySuspended = false

    private var generation: UInt64 = 0
    private var cpuHistory = RingBuffer(windowSeconds: 60)
    /// Sized on the first per-core reading rather than at init: the core count
    /// is a runtime fact, and a hardcoded 18 would silently truncate on any
    /// other Mac.
    private var perCoreHistory: [RingBuffer] = []
    private var memHistory = RingBuffer(windowSeconds: 60)
    // Throughput history is stored as a log-normalized 0…1 fraction (the
    // same curve the glyph's activity arrows use) so a plain fixed-scale
    // GraphView renders it log-scaled — net/disk span orders of magnitude,
    // which a linear sparkline would flatten. One value/tick = total
    // (in+out) activity. Filled every tick while net/disk are bar-enabled
    // (full 60 s backstory on open); otherwise fills from panel-open.
    private var netHistory = RingBuffer(windowSeconds: 60)
    private var diskHistory = RingBuffer(windowSeconds: 60)

    /// Last memory-pressure level read from the kernel; refreshed once per
    /// tick and passed into every memory sample.
    private var currentPressure: MemoryPressure = .normal

    private let log = Logger(subsystem: "dev.sys-monitor.menubar", category: "sampling")

    /// `SYSMON_DEBUG=1` enables a per-tick state line (stream-only debug
    /// level) so field bug reports are diagnosable with `log stream`
    /// instead of an instrumented rebuild.
    private let debugTicks = ProcessInfo.processInfo.environment["SYSMON_DEBUG"] == "1"

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

    /// Push the user's alert configuration (enable + thresholds). Routed
    /// through the queue because the evaluator is queue-isolated state.
    public func updateAlertConfig(_ config: AlertConfig) {
        queue.async { [weak self] in self?.alertEvaluator.config = config }
    }

    public func updateSeverityThresholds(_ t: SeverityThresholds) {
        queue.async { [weak self] in self?.currentThresholds = t }
    }

    /// Set the sparkline history window (seconds) on all four ring buffers.
    /// Queue-isolated; widening keeps existing points, narrowing trims.
    public func updateHistoryWindow(_ seconds: TimeInterval) {
        queue.async { [weak self] in
            guard let self else { return }
            let now = monoSeconds()
            self.cpuHistory.setWindow(seconds, now: now)
            for i in self.perCoreHistory.indices {
                self.perCoreHistory[i].setWindow(seconds, now: now)
            }
            self.memHistory.setWindow(seconds, now: now)
            self.netHistory.setWindow(seconds, now: now)
            self.diskHistory.setWindow(seconds, now: now)
        }
    }

    /// Install the main-actor sink that posts notifications for fired
    /// alerts. Set once at startup, before sampling produces any tick.
    public func setAlertHandler(_ handler: @escaping @MainActor @Sendable ([AlertEvent]) -> Void) {
        queue.async { [weak self] in self?.onAlert = handler }
    }

    /// Start the sampler in idle tier. Idempotent.
    public func startIdleTier() {
        queue.async { [weak self] in
            guard let self else { return }
            self.desiredTier = .idle
            self.transitionToIdle()
        }
    }

    /// Switch into open tier (panel is visible). Idempotent — calling while
    /// already open is a no-op so flap-clicks don't restart the timer.
    public func enterOpenTier() {
        queue.async { [weak self] in
            guard let self else { return }
            self.desiredTier = .open
            if self.activeTier == .open { return }
            self.transitionToOpen()
        }
    }

    /// Switch back to idle tier (panel was dismissed). Idempotent.
    public func enterIdleTier() {
        queue.async { [weak self] in
            guard let self else { return }
            self.desiredTier = .idle
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

    /// Stop sampling entirely while nobody can see the output (display
    /// asleep or screen locked). System sleep suspends the timer queue for
    /// free; a locked-but-awake Mac does not, so without this the widget
    /// keeps paying full sampling + render cost into a black screen.
    public func suspendForDisplaySleep() {
        queue.async { [weak self] in
            guard let self, !self.displaySuspended else { return }
            self.displaySuspended = true
            self.idleTimer?.cancel()
            self.openTimer?.cancel()
            self.idleTimer = nil
            self.openTimer = nil
            self.log.info("sampling suspended (display sleep / lock)")
        }
    }

    /// Resume after the display wakes / unlocks, restoring whichever tier
    /// the shell most recently asked for (a panel opened while the display
    /// was dark had its open-tier request refused — honor it now).
    /// Baselines are dropped so the first tick measures fresh instead of
    /// deltaing across the dark gap.
    public func resumeFromDisplaySleep() {
        queue.async { [weak self] in
            guard let self, self.displaySuspended else { return }
            self.displaySuspended = false
            self.dropAllBaselines()
            switch self.desiredTier {
            case .idle: self.transitionToIdle()
            case .open: self.transitionToOpen()
            }
            self.log.info("sampling resumed (display wake / unlock)")
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
            // Drop the clock with the counter. A nil counter already forces
            // a re-baseline on its own, so this is not load-bearing today;
            // it keeps the pair in step so a later edit cannot leave a live
            // clock beside a dropped counter, which is the exact shape of
            // the reopen spike.
            if !net  { self.prevNet  = nil; self.netClock.reset() }
            if !disk { self.prevDisk = nil; self.diskClock.reset() }
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

    // MARK: - Memory pressure (run only on `queue`)

    /// Refresh the latched memory-pressure level from the kernel. Called
    /// once per tick.
    ///
    /// Deliberately a sysctl poll, NOT `DispatchSource.makeMemoryPressureSource`:
    /// the kernel delivers warn-level pressure *events* selectively — largest
    /// memory consumers first, only as many processes as needed to relieve
    /// pressure — so a small menu-bar app can sit through a whole warn episode
    /// without ever receiving the event (observed under induced pressure: the
    /// sysctl read 2 while the source stayed silent). The sysctl reports the
    /// host-wide level unconditionally; one read per tick is microsecond-cheap.
    private func refreshPressureLevel() {
        var raw: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &raw, &size, nil, 0) == 0 else {
            return  // keep the last known level; next tick retries
        }
        // Kernel levels: 1 = normal, 2 = warning, 4 = critical.
        let level: MemoryPressure
        switch raw {
        case 4:  level = .critical
        case 2:  level = .warn
        default: level = .normal
        }
        if level != currentPressure {
            currentPressure = level
            log.info("memory pressure -> \(String(describing: level), privacy: .public)")
        }
    }

    // MARK: - Tier transitions (run only on `queue`)

    private func transitionToIdle() {
        guard !displaySuspended else { return }
        openTimer?.cancel()
        openTimer = nil
        openTickIndex = 0
        lastProcSampleTime = 0
        lastProcMetric = .measuring
        // Per-core and process state are open-tier only — drop them so a
        // stale value never gets reused. NET/DISK prevs ARE preserved:
        // if the user keeps those in the bar, the idle tier also samples
        // them, so the rate keeps computing across the transition. The
        // gap-based re-baseline in readNet/readDisk handles the case
        // where idle doesn't sample them (stale prev is detected by
        // elapsed > N×tick).
        prevPerCore = nil
        prevProcCpu.removeAll(keepingCapacity: true)
        prevProcDisk.removeAll(keepingCapacity: true)
        prevProcNet.removeAll(keepingCapacity: true)
        prevProcEnergy.removeAll(keepingCapacity: true)

        // Generous leeway on the idle tier: nothing about the glyph needs
        // sub-second precision, and the rate math divides by measured
        // elapsed, so accuracy is unaffected. Apple's floor is 10% of the
        // interval; the wider window lets the kernel coalesce our wakeup
        // with others.
        // Per-process network monitoring is open-tier only — stop the
        // NStat query timer when the panel closes.
        netMonitor.stop()

        startTimer(
            cadence: idleCadenceSeconds,
            leeway: max(0.05, idleCadenceSeconds * 0.1),
            assignTo: { [weak self] t in self?.idleTimer = t },
            handler: { [weak self] in self?.idleTick() }
        )
        activeTier = .idle
    }

    private func transitionToOpen() {
        guard !displaySuspended else { return }
        idleTimer?.cancel()
        idleTimer = nil
        openTickIndex = 0
        lastProcSampleTime = 0
        lastProcMetric = .measuring
        // Per-core/process are open-tier only and need fresh baselines.
        // NET/DISK prevs survive deliberately: when the idle tier was
        // sampling them they are fresh, and the first open tick can emit a
        // rate immediately. When it was not, their own clocks make the
        // interval read as a gap and they re-baseline. That used to be
        // asserted rather than true, which is the reopen spike.
        prevPerCore = nil
        prevProcCpu.removeAll(keepingCapacity: true)
        prevProcDisk.removeAll(keepingCapacity: true)
        prevProcNet.removeAll(keepingCapacity: true)
        prevProcEnergy.removeAll(keepingCapacity: true)

        // Per-process network counters are only worth their cost while
        // the process list is visible — start the NStat query timer with
        // the open tier.
        netMonitor.start()
        // Power is panel-tier; re-baseline so the first open read isn't a
        // delta across the whole closed period.
        powerMonitor.resetBaseline()

        // Open tier keeps a tight leeway — the panel is on screen and
        // visual liveness is the point while it's open.
        startTimer(
            cadence: openCadenceSeconds,
            leeway: 0.05,
            assignTo: { [weak self] t in self?.openTimer = t },
            handler: { [weak self] in self?.openTick() }
        )
        activeTier = .open

        // One extra early tick at ~+300 ms: the timer's first tick (+20 ms)
        // is the process baseline, so without this the first process DATA
        // arrives a full cadence later. A ~280 ms %CPU window is noisier
        // but fine for a first paint — the next regular tick corrects it.
        openEpoch &+= 1
        let epoch = openEpoch
        queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
            guard let self,
                  self.openEpoch == epoch,
                  self.activeTier == .open,
                  !self.displaySuspended else { return }
            self.openTick()
        }
    }

    private func startTimer(
        cadence: Double,
        leeway: Double,
        assignTo: (DispatchSourceTimer) -> Void,
        handler: @escaping () -> Void
    ) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(
            deadline: .now() + .milliseconds(20),
            repeating: .milliseconds(Int(cadence * 1000.0)),
            leeway: .milliseconds(Int(leeway * 1000.0))
        )
        t.setEventHandler(handler: handler)
        t.resume()
        assignTo(t)
        log.info("timer scheduled cadence=\(cadence, privacy: .public)s leeway=\(Int(leeway * 1000), privacy: .public)ms")
    }

    private func dropAllBaselines() {
        prevOverall = nil
        prevPerCore = nil
        prevNet = nil
        prevDisk = nil
        prevProcCpu.removeAll(keepingCapacity: true)
        prevProcDisk.removeAll(keepingCapacity: true)
        prevProcNet.removeAll(keepingCapacity: true)
        prevProcEnergy.removeAll(keepingCapacity: true)
        prevTickTime = 0
        prevTickCadence = 0
        lastProcSampleTime = 0
        netClock.reset()
        diskClock.reset()
        // Memory's baseline would survive a tier switch correctly, since it is
        // sampled in both tiers and SampleClock already judges the cadence
        // change. It is dropped with its counter anyway, to keep the pair in
        // step: a live clock beside a dropped counter is the reopen-spike
        // shape, and the cost here is one tick of reclaim rate.
        memClock.reset()
        prevMemRaw = nil
        lastProcMetric = .measuring
    }

    /// Gap test for the main tick — thin wrapper over the pure
    /// `RateMath.isGap` (which is unit-tested for the FB-2/FB-4 case),
    /// binding it to this coordinator's `prevTickCadence` and multiplier.
    private func isGapTick(elapsed: TimeInterval, cadence: Double) -> Bool {
        RateMath.isGap(elapsed: elapsed, cadence: cadence,
                       prevCadence: prevTickCadence, gapMultiplier: gapMultiplier)
    }

    // MARK: - Ticks

    /// Idle tier: overall CPU + memory always; NET / DISK only if a
    /// corresponding bar cell asked for them. Process enumeration is
    /// never in idle tier.
    private func idleTick() {
        let now = monoSeconds()
        let elapsed = (prevTickTime > 0) ? (now - prevTickTime) : 0
        let isGap = isGapTick(elapsed: elapsed, cadence: idleCadenceSeconds)

        refreshPressureLevel()
        let cpuMetric  = readOverallCPU(now: now, isGap: isGap)
        let memMetric  = readMemory(now: now, cadence: idleCadenceSeconds)
        let netMetric: Metric<Throughput> = idleSamplesNet
            ? readNet(now: now, cadence: idleCadenceSeconds)
            : .measuring
        let diskMetric: Metric<Throughput> = idleSamplesDisk
            ? readDisk(now: now, cadence: idleCadenceSeconds)
            : .measuring

        prevTickTime = now
        prevTickCadence = idleCadenceSeconds
        publishSnapshot(
            cpu: cpuMetric,
            memory: memMetric,
            processes: .measuring,
            net: netMetric,
            disk: diskMetric,
            power: .measuring,
            battery: batterySampler.read(),
            // Read in the idle tier too, not because the footer needs it (the
            // panel is shut) but because the glyph's CPU colour now keys on it.
            // Leaving it panel-only would make the menu bar and the panel
            // disagree about the same metric, which is the defect the memory
            // colour hit an hour earlier. Two cheap syscalls per tick.
            loadAverage: loadSampler.read()
        )
    }

    /// Open tier: full sweep — overall + per-core CPU, memory, processes,
    /// network, disk. Process enumeration is the expensive operation and
    /// runs ONLY here.
    private func openTick() {
        let now = monoSeconds()
        let elapsed = (prevTickTime > 0) ? (now - prevTickTime) : 0
        let isGap = isGapTick(elapsed: elapsed, cadence: openCadenceSeconds)

        refreshPressureLevel()
        let cpuMetric  = readFullCPU(now: now, isGap: isGap)
        let memMetric  = readMemory(now: now, cadence: openCadenceSeconds)
        let netMetric  = readNet(now: now, cadence: openCadenceSeconds)
        let diskMetric = readDisk(now: now, cadence: openCadenceSeconds)

        // Process enumeration every 2nd tick — see the divisor comment on
        // `openTickIndex`. Ticks 1 and 2 both sample so the early tick
        // (scheduled by `transitionToOpen`) can deliver the first process
        // data ~300 ms after open instead of two full cadences later.
        // Skipped ticks re-publish the last list so the panel doesn't flash.
        openTickIndex &+= 1
        if openTickIndex <= 2 || openTickIndex % 2 == 1 {
            lastProcMetric = readProcesses(now: now)
        }

        // Package power — panel-tier only. nil until a baseline exists
        // (first open tick) or when IOReport is unavailable.
        let powerMetric: Metric<PowerSample> = powerMonitor.isAvailable
            ? (powerMonitor.read(now: now).map { .ok($0) } ?? .measuring)
            : .unavailable

        prevTickTime = now
        prevTickCadence = openCadenceSeconds
        publishSnapshot(
            cpu: cpuMetric,
            memory: memMetric,
            processes: lastProcMetric,
            net: netMetric,
            disk: diskMetric,
            power: powerMetric,
            battery: batterySampler.read(),
            // Storage is panel-tier: nothing renders it while the panel is
            // shut. Load average is not, because the glyph's CPU colour keys
            // on it, so `idleTick` reads it too.
            diskSpace: diskSpaceSampler.read(),
            loadAverage: loadSampler.read(),
            perInterfaceNet: lastPerInterfaceNet
        )
    }

    // MARK: - Per-metric reads (run only on `queue`)

    private func readOverallCPU(now: TimeInterval, isGap: Bool) -> Metric<CPUSample> {
        let ticks: CPUTicks
        do { ticks = try cpuSampler.readOverallTicks() } catch { return .unavailable }
        defer { prevOverall = ticks }

        guard let prev = prevOverall, !isGap else { return .measuring }
        let overall = RateMath.cpuUtilization(prev: prev, now: ticks)
        cpuHistory.append(HistoryPoint(timestamp: now, value: overall))
        return .ok(CPUSample(overall: overall, perCore: []))
    }

    private func readFullCPU(now: TimeInterval, isGap: Bool) -> Metric<CPUSample> {
        let counters: CPUCounters
        do { counters = try cpuSampler.read() } catch { return .unavailable }
        defer {
            prevOverall = counters.overall
            prevPerCore = counters.perCore
        }

        guard let prev = prevOverall, !isGap else { return .measuring }
        let overall = RateMath.cpuUtilization(prev: prev, now: counters.overall)
        cpuHistory.append(HistoryPoint(timestamp: now, value: overall))

        // Per-core needs its own prev because we may have just entered the
        // open tier and the idle tier never collected per-core readings.
        let perCore: [Double]
        if let pp = prevPerCore, pp.count == counters.perCore.count {
            perCore = RateMath.cpuPerCore(prev: pp, now: counters.perCore)
            if perCoreHistory.count != perCore.count {
                perCoreHistory = (0..<perCore.count).map { _ in
                    RingBuffer(windowSeconds: cpuHistory.windowSeconds)
                }
            }
            for (i, v) in perCore.enumerated() {
                perCoreHistory[i].append(HistoryPoint(timestamp: now, value: v))
            }
        } else {
            perCore = []  // first open tick — show the strip empty until the next tick
        }
        return .ok(CPUSample(overall: overall, perCore: perCore))
    }

    private func readMemory(now: TimeInterval, cadence: Double) -> Metric<MemorySample> {
        let (elapsed, isGap) = memClock.evaluate(
            now: now, cadence: cadence, gapMultiplier: gapMultiplier)

        let raw: MemoryRaw
        // A failed read drops the baseline with the clock, so recovery
        // re-baselines instead of deltaing an outage's worth of pages over
        // one tick. Same pairing rule as NET and DISK.
        do { raw = try memSampler.read() } catch {
            prevMemRaw = nil
            memClock.reset()
            return .unavailable
        }
        defer { prevMemRaw = raw; memClock.stamp(now: now, cadence: cadence) }

        if raw.physicalTotalBytes > 0 {
            let frac = Double(raw.usedBytes) / Double(raw.physicalTotalBytes)
            memHistory.append(HistoryPoint(timestamp: now, value: frac))
        }

        // Unlike NET and DISK, a missing rate never downgrades this metric to
        // `.measuring`: memory is instantaneous and ships `.ok` on the first
        // sample (FR-16). Only `reclaim` waits for a second reading.
        var reclaim: ReclaimRate?
        if let prev = prevMemRaw, !isGap,
           let decomp  = RateMath.pagesPerSec(prev: prev.decompressions, now: raw.decompressions, elapsed: elapsed),
           let swapin  = RateMath.pagesPerSec(prev: prev.swapins,        now: raw.swapins,        elapsed: elapsed),
           let comp    = RateMath.pagesPerSec(prev: prev.compressions,   now: raw.compressions,   elapsed: elapsed),
           let swapout = RateMath.pagesPerSec(prev: prev.swapouts,       now: raw.swapouts,       elapsed: elapsed) {
            reclaim = ReclaimRate(stallPagesPerSec: decomp + swapin,
                                  evictPagesPerSec: comp + swapout)
        }
        return .ok(raw.toSample(pressure: currentPressure, reclaim: reclaim))
    }

    private func readNet(now: TimeInterval, cadence: Double) -> Metric<Throughput> {
        let (elapsed, isGap) = netClock.evaluate(
            now: now, cadence: cadence, gapMultiplier: gapMultiplier)

        let counters: NetCounters
        // A failed read must also drop the baseline: a prev that survives an
        // outage would delta N ticks of bytes over one tick's elapsed — an
        // N× rate spike on recovery.
        do { counters = try netSampler.read() } catch {
            prevNet = nil
            netClock.reset()
            lastPerInterfaceNet = []
            return .unavailable
        }
        defer { prevNet = counters; netClock.stamp(now: now, cadence: cadence) }
        lastPerInterfaceNet = []   // cleared unless this tick produces a rate

        guard let prev = prevNet, !isGap else { return .measuring }
        // Interface set changed (VPN flip, USB plug) → treat as gap.
        if prev.ifaceSet != counters.ifaceSet { return .measuring }
        guard
            let inBps  = RateMath.bytesPerSec(prev: prev.inBytes,  now: counters.inBytes,  elapsed: elapsed),
            let outBps = RateMath.bytesPerSec(prev: prev.outBytes, now: counters.outBytes, elapsed: elapsed)
        else { return .measuring }
        netHistory.append(HistoryPoint(timestamp: now, value: Self.throughputFrac(inBps + outBps)))
        lastPerInterfaceNet = Self.perInterfaceRates(prev: prev, now: counters, elapsed: elapsed)
        return .ok(Throughput(inPerSec: inBps, outPerSec: outBps))
    }

    /// Per-interface rates from two cumulative readings. Skips interfaces
    /// absent from the prior reading (just appeared) and idle ones; sorted
    /// busiest-first. Pure — no instance state — so it's unit-testable.
    static func perInterfaceRates(prev: NetCounters, now: NetCounters,
                                  elapsed: TimeInterval) -> [InterfaceThroughput] {
        guard elapsed > 0 else { return [] }
        var out: [InterfaceThroughput] = []
        for (name, cur) in now.perInterface {
            guard let p = prev.perInterface[name],
                  let inBps  = RateMath.bytesPerSec(prev: p.inBytes,  now: cur.inBytes,  elapsed: elapsed),
                  let outBps = RateMath.bytesPerSec(prev: p.outBytes, now: cur.outBytes, elapsed: elapsed)
            else { continue }
            if inBps + outBps < 1 { continue }   // hide idle interfaces
            out.append(InterfaceThroughput(name: name, inPerSec: inBps, outPerSec: outBps))
        }
        return out.sorted { ($0.inPerSec + $0.outPerSec) > ($1.inPerSec + $1.outPerSec) }
    }

    /// Log-normalize bytes/sec into 0…1 for the sparkline. Mirrors the
    /// glyph's activity-arrow curve: silence → 0, ~10 MB/s → ~1.0.
    static func throughputFrac(_ bps: Double) -> Double {
        guard bps >= 100 else { return 0 }
        let maxLog = log10(10.0 * 1_048_576.0)   // ≈ 7.02
        return max(0, min(1, log10(bps) / maxLog))
    }

    private func readDisk(now: TimeInterval, cadence: Double) -> Metric<Throughput> {
        let (elapsed, isGap) = diskClock.evaluate(
            now: now, cadence: cadence, gapMultiplier: gapMultiplier)

        let counters: DiskCounters
        // Same baseline-drop rule as readNet — see the comment there.
        do { counters = try diskSampler.read() } catch {
            prevDisk = nil
            diskClock.reset()
            return .unavailable
        }
        defer { prevDisk = counters; diskClock.stamp(now: now, cadence: cadence) }

        guard let prev = prevDisk, !isGap else { return .measuring }
        guard
            let rBps = RateMath.bytesPerSec(prev: prev.readBytes,  now: counters.readBytes,  elapsed: elapsed),
            let wBps = RateMath.bytesPerSec(prev: prev.writeBytes, now: counters.writeBytes, elapsed: elapsed)
        else { return .measuring }
        diskHistory.append(HistoryPoint(timestamp: now, value: Self.throughputFrac(rBps + wBps)))
        return .ok(Throughput(inPerSec: rBps, outPerSec: wBps))
    }

    private func readProcesses(now: TimeInterval) -> Metric<[ProcSample]> {
        // Runs on its own divisor, so it keeps its own elapsed clock —
        // the shared per-tick `elapsed` would halve the window and double
        // every %CPU value.
        let elapsed = (lastProcSampleTime > 0) ? (now - lastProcSampleTime) : 0
        let sampleInterval = openCadenceSeconds * 2
        let isGap = (elapsed <= 0) || (elapsed > sampleInterval * gapMultiplier)

        let raws: [ProcRaw]
        // Per-process %CPU is Δcpu-time / Δwall — the same stale-baseline
        // inflation as NET/DISK applies, so a failed enumeration drops the
        // whole prev map and the next success re-baselines.
        do { raws = try procSampler.read() } catch {
            prevProcCpu.removeAll(keepingCapacity: true)
            prevProcDisk.removeAll(keepingCapacity: true)
            prevProcNet.removeAll(keepingCapacity: true)
            prevProcEnergy.removeAll(keepingCapacity: true)
            lastProcSampleTime = 0
            return .unavailable
        }
        lastProcSampleTime = now

        // Per-pid cumulative network bytes from the private-framework
        // monitor (empty when it's unavailable). Snapshot once per tick,
        // passing the live pid set so the monitor can prune retired bytes
        // for processes that have exited.
        let livePids = Set(raws.map { $0.pid })
        let netByPid = netMonitor.cumulativeBytesByPid(livePids: livePids)

        // Build the next prev maps regardless, so the next tick can
        // delta even if this one returns `.measuring`.
        var nextPrevCpu: [Int32: UInt64] = [:]
        var nextPrevDisk: [Int32: UInt64] = [:]
        var nextPrevNet: [Int32: UInt64] = [:]
        var nextPrevEnergy: [Int32: UInt64] = [:]
        nextPrevCpu.reserveCapacity(raws.count)
        nextPrevDisk.reserveCapacity(raws.count)
        nextPrevNet.reserveCapacity(raws.count)
        nextPrevEnergy.reserveCapacity(raws.count)

        var samples: [ProcSample] = []
        samples.reserveCapacity(raws.count)

        // Phase guard: we need a previous reading AND a non-gap elapsed to
        // compute per-process rates.
        let canCompute = !isGap && elapsed > 0 && !prevProcCpu.isEmpty
        let elapsedNs = elapsed * 1_000_000_000

        for raw in raws {
            nextPrevCpu[raw.pid] = raw.cpuTimeNs
            nextPrevDisk[raw.pid] = raw.diskBytes
            let netCumulative = netByPid[raw.pid] ?? 0
            nextPrevNet[raw.pid] = netCumulative
            nextPrevEnergy[raw.pid] = raw.energyNanojoules
            if canCompute, let prevNs = prevProcCpu[raw.pid], raw.cpuTimeNs >= prevNs {
                // Δns CPU-time / Δns wall-clock = fraction of one core,
                // matching Activity Monitor's convention (can exceed 1.0
                // for multi-threaded processes spanning cores).
                let cpu = Double(raw.cpuTimeNs - prevNs) / elapsedNs
                var diskBps = 0.0
                if let prevDisk = prevProcDisk[raw.pid], raw.diskBytes >= prevDisk {
                    diskBps = Double(raw.diskBytes - prevDisk) / elapsed
                }
                var netBps = 0.0
                if let prevNet = prevProcNet[raw.pid], netCumulative >= prevNet {
                    netBps = Double(netCumulative - prevNet) / elapsed
                }
                // Nanojoules over seconds is watts. Same wrap rule as the
                // byte counters: a backwards reading means the process was
                // replaced under its pid, so report 0 rather than a spike.
                var watts = 0.0
                if let prevE = prevProcEnergy[raw.pid], raw.energyNanojoules >= prevE {
                    watts = Double(raw.energyNanojoules - prevE) / 1_000_000_000 / elapsed
                }
                samples.append(ProcSample(
                    raw: raw, cpu: cpu, diskBps: diskBps, netBps: netBps, watts: watts
                ))
            }
        }
        prevProcCpu = nextPrevCpu
        prevProcDisk = nextPrevDisk
        prevProcNet = nextPrevNet
        prevProcEnergy = nextPrevEnergy

        if !canCompute { return .measuring }
        return .ok(samples)
    }

    /// The colours' own verdict, so the notification cannot disagree with what
    /// the menu bar is showing. Returning `.normal` suppresses the alert for
    /// that metric entirely: a machine that looks calm must not buzz.
    private func severityForAlerts(cpu: Metric<CPUSample>,
                                   memory: Metric<MemorySample>,
                                   loadAverage: LoadAverage?) -> (cpu: MetricSeverity, mem: MetricSeverity) {
        var cpuSev: MetricSeverity = .normal
        if case .ok(let c) = cpu {
            let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
            let q = loadAverage.map { $0.one / max(cores, 1) }
            cpuSev = RateMath.cpuSeverity(utilisation: c.overall,
                                          runQueuePerCore: q,
                                          gate: currentThresholds.cpuWarn)
        }
        var memSev: MetricSeverity = .normal
        if case .ok(let m) = memory { memSev = m.severity }
        return (cpuSev, memSev)
    }

    // MARK: - Publish

    private func publishSnapshot(
        cpu: Metric<CPUSample>,
        memory: Metric<MemorySample>,
        processes: Metric<[ProcSample]>,
        net: Metric<Throughput>,
        disk: Metric<Throughput>,
        power: Metric<PowerSample>,
        battery: BatterySample?,
        diskSpace: DiskSpaceSample? = nil,
        loadAverage: LoadAverage? = nil,
        perInterfaceNet: [InterfaceThroughput] = []
    ) {
        generation &+= 1
        if debugTicks {
            func s<T>(_ m: Metric<T>) -> String {
                switch m {
                case .ok: return "ok"
                case .measuring: return "meas"
                case .unavailable: return "unav"
                }
            }
            log.debug("tick gen=\(self.generation) tier=\(self.activeTier == .open ? "open" : "idle", privacy: .public) cpu=\(s(cpu), privacy: .public) mem=\(s(memory), privacy: .public) net=\(s(net), privacy: .public) disk=\(s(disk), privacy: .public) proc=\(s(processes), privacy: .public)")
        }
        let snap = MetricsSnapshot(
            generation: generation,
            cpu: cpu,
            memory: memory,
            processes: processes,
            net: net,
            disk: disk,
            power: power,
            battery: battery,
            diskSpace: diskSpace,
            loadAverage: loadAverage,
            perInterfaceNet: perInterfaceNet,
            cpuHistory: cpuHistory,
            perCoreHistory: perCoreHistory,
            memHistory: memHistory,
            netHistory: netHistory,
            diskHistory: diskHistory,
            perProcessNetAvailable: netMonitor.isAvailable,
            powerAvailable: powerMonitor.isAvailable
        )
        // Evaluate alerts on the queue (the evaluator is queue-isolated).
        // Loads are nil when the metric isn't .ok this tick → the evaluator
        // treats that as "no reading" and won't alert on missing data.
        //
        // The alert is a third surface and must agree with the other two. Fed
        // the raw fractions it fired on a busy-but-responsive machine while
        // the glyph and panel stayed green, and stayed silent at 71% while
        // thrashing when both of them went amber. So it is gated by the same
        // severity the colours use, and the user's threshold then decides how
        // far past that it has to go.
        let sev = severityForAlerts(cpu: cpu, memory: memory, loadAverage: loadAverage)
        let cpuLoad: Double? = {
            guard case .ok(let v) = cpu, sev.cpu != .normal else { return nil }
            return v.overall
        }()
        let memLoad: Double? = {
            guard case .ok(let v) = memory, v.totalBytes > 0, sev.mem != .normal else { return nil }
            return Double(v.usedBytes) / Double(v.totalBytes)
        }()
        let alerts = alertEvaluator.evaluate(cpuLoad: cpuLoad, memLoad: memLoad, now: monoSeconds())
        let alertHandler = onAlert

        // The hop is an unordered Task — under main-thread starvation two
        // ticks' publishes can land out of order, so never let an older
        // generation overwrite a newer one. The `>` is not wrap-safe, but
        // a UInt64 tick counter cannot wrap on any real timescale
        // (~585 billion years at 1 Hz); ordering protection matters,
        // wrap does not.
        Task { @MainActor [weak store, log] in
            if !alerts.isEmpty { alertHandler?(alerts) }
            guard let store else { return }
            guard snap.generation > store.snapshot.generation else {
                log.debug("dropped out-of-order snapshot gen \(snap.generation) (store at \(store.snapshot.generation))")
                return
            }
            store.snapshot = snap
        }
    }
}

// Monotonic seconds (CLOCK_MONOTONIC) — deliberately NOT wall-clock, so a
// user clock change or NTP step can't corrupt an elapsed interval. Same
// helper used by the probe so "elapsed" means the same thing everywhere.
@inline(__always)
func monoSeconds() -> TimeInterval {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000
}
