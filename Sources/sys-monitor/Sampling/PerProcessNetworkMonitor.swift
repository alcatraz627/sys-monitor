import Foundation
import os

/// Per-process network byte counters, sourced from the PRIVATE
/// `NetworkStatistics.framework` — the same userland API `nettop` and
/// Activity Monitor use. macOS exposes no public per-pid network
/// counters, and this project already accepts one private framework
/// behind an adapter (IOReport, for power); this is the network twin,
/// held to the same contract: every private symbol is resolved at
/// runtime, ANY failure degrades the whole monitor to "unavailable"
/// without touching the rest of the app, and nothing here is reachable
/// on the idle path.
///
/// Counter model: the framework reports cumulative bytes PER FLOW
/// (TCP/UDP source), pull-delivered only in response to a periodic
/// `NStatManagerQueryAllSources` call. This monitor sums flows by pid
/// into a monotonic per-pid cumulative total (live flows + bytes
/// retired from closed flows). The coordinator deltas that total across
/// process ticks exactly like the cpu-time and disk maps, so all the
/// existing rate discipline (gap handling, drop-on-failure) applies
/// unchanged.
final class PerProcessNetworkMonitor: @unchecked Sendable {

    /// True once every required symbol resolved and the manager was
    /// created. When false the monitor is inert and reports no data.
    private(set) var isAvailable = false

    private let queue = DispatchQueue(label: "sys-monitor.netstat")
    private let log = Logger(subsystem: "dev.sys-monitor.menubar", category: "netstat")

    // Resolved private symbols (nil until/unless resolution succeeds).
    private typealias CreateT = @convention(c) (CFAllocator?, DispatchQueue, @escaping @convention(block) (UnsafeMutableRawPointer?) -> Void) -> UnsafeMutableRawPointer?
    private typealias SrcBlockT = @convention(c) (UnsafeMutableRawPointer?, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    private typealias AddAllT = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias QueryT = @convention(c) (UnsafeMutableRawPointer?, (@convention(block) () -> Void)?) -> Void

    private typealias RemovedBlockT = @convention(c) (UnsafeMutableRawPointer?, @escaping @convention(block) () -> Void) -> Void

    private var setDesc: SrcBlockT?
    private var setCounts: SrcBlockT?
    private var setRemoved: RemovedBlockT?
    private var queryAll: QueryT?         // counts-only; cross-version
    private var queryUpdate: QueryT?      // counts+desc; newer macOS, preferred
    private var queryDescription: AddAllT?
    private var manager: UnsafeMutableRawPointer?

    private var kPID: CFString?
    private var kRx: CFString?
    private var kTx: CFString?
    private var kName: CFString?

    // Per-flow accounting. A flow contributes only the bytes observed
    // WHILE WE WATCH IT: `contribution = latest − baseline`, where
    // baseline is the flow's cumulative the first time we saw it. This
    // is what stops a pre-existing flow (e.g. a Steam download already
    // running when the panel opens) from dumping its entire lifetime
    // total into one tick as a phantom multi-Gbps spike.
    // cumulative[pid] = retired[pid] + Σ live contributions for that pid.
    private struct Flow { var pid: Int32; var baseline: UInt64?; var latest: UInt64 }
    private var liveFlows: [UInt: Flow] = [:]
    private var retired: [Int32: UInt64] = [:]

    private var queryTimer: DispatchSourceTimer?
    private var started = false

    init() {
        queue.sync { self.setup() }
    }

    /// Begin querying (open tier). Idempotent. No-op if unavailable.
    func start() {
        queue.async { [weak self] in
            guard let self, self.isAvailable, !self.started else { return }
            self.started = true
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(200))
            t.setEventHandler { [weak self] in
                guard let self else { return }
                // Prefer the combined counts+description query: on recent
                // macOS the counts-only `QueryAllSources` does not refresh
                // the per-flow byte totals, while `...Update` does. Fall
                // back to counts-only where Update is absent.
                if let upd = self.queryUpdate { upd(self.manager, nil) }
                else if let q = self.queryAll { q(self.manager, nil) }
            }
            t.resume()
            self.queryTimer = t
        }
    }

    /// Stop querying (idle tier). The manager stays alive but goes quiet;
    /// drop the accumulated flow state so it can't grow while we're not
    /// even reading it (new-source/removed callbacks keep firing on the
    /// live manager regardless of the query timer). The next `start()`
    /// re-baselines from scratch — correct, because the coordinator
    /// clears `prevProcNet` on every tier transition anyway.
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.queryTimer?.cancel()
            self.queryTimer = nil
            self.started = false
            self.liveFlows.removeAll()
            self.retired.removeAll()
        }
    }

    /// Monotonic cumulative rx+tx bytes per pid, for the coordinator to
    /// delta. Empty when unavailable.
    ///
    /// `livePids` (the current process set) prunes the `retired` bucket
    /// to processes that still exist — a panel left open for days would
    /// otherwise keep one retired entry per pid ever seen. A dead pid's
    /// retired bytes are safe to drop: if its number is recycled, the new
    /// process's flows re-baseline from zero.
    func cumulativeBytesByPid(livePids: Set<Int32>) -> [Int32: UInt64] {
        queue.sync {
            guard isAvailable else { return [:] }
            retired = retired.filter { livePids.contains($0.key) }
            var out = retired
            for (_, flow) in liveFlows where flow.pid > 0 {
                if let base = flow.baseline, flow.latest >= base {
                    out[flow.pid, default: 0] &+= flow.latest - base
                }
            }
            return out
        }
    }

    // MARK: - Setup (runs once, on `queue`)

    private func setup() {
        let path = "/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics"
        guard let h = dlopen(path, RTLD_NOW) else {
            log.info("netstat unavailable: dlopen failed")
            return
        }
        func fn<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        // Key constants are CFString data symbols; the dict is keyed by
        // those exact CFStrings, so we read the value AT the symbol
        // address and use it directly as the key.
        func key(_ name: String) -> CFString? {
            guard let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p.load(as: UnsafeRawPointer.self), to: CFString.self)
        }

        guard
            let create = fn("NStatManagerCreate", CreateT.self),
            let sDesc = fn("NStatSourceSetDescriptionBlock", SrcBlockT.self),
            let sCounts = fn("NStatSourceSetCountsBlock", SrcBlockT.self),
            let sRemoved = fn("NStatSourceSetRemovedBlock", RemovedBlockT.self),
            let addTCP = fn("NStatManagerAddAllTCP", AddAllT.self),
            let addUDP = fn("NStatManagerAddAllUDP", AddAllT.self),
            let query = fn("NStatManagerQueryAllSources", QueryT.self),
            let queryDesc = fn("NStatSourceQueryDescription", AddAllT.self),
            let pidK = key("kNStatSrcKeyPID"),
            let rxK = key("kNStatSrcKeyRxBytes"),
            let txK = key("kNStatSrcKeyTxBytes"),
            let nameK = key("kNStatSrcKeyProcessName")
        else {
            log.info("netstat unavailable: symbol resolution failed")
            return
        }
        self.setDesc = sDesc
        self.setCounts = sCounts
        self.setRemoved = sRemoved
        self.queryAll = query
        self.queryUpdate = fn("NStatManagerQueryAllSourcesUpdate", QueryT.self)  // optional
        self.queryDescription = queryDesc
        self.kPID = pidK; self.kRx = rxK; self.kTx = txK; self.kName = nameK

        let mgr = create(kCFAllocatorDefault, queue) { [weak self] source in
            self?.onNewSource(source)
        }
        guard let mgr else {
            log.info("netstat unavailable: NStatManagerCreate returned nil")
            return
        }
        self.manager = mgr
        addTCP(mgr)
        addUDP(mgr)
        self.isAvailable = true
        log.info("netstat available — per-process network counters online")
    }

    // MARK: - Source callbacks (all on `queue`)

    private func onNewSource(_ source: UnsafeMutableRawPointer?) {
        guard let source, let setDesc, let setCounts else { return }
        let token = UInt(bitPattern: source)
        liveFlows[token] = Flow(pid: 0, baseline: nil, latest: 0)
        queryDescription?(source)   // force early pid/name resolution

        setDesc(source) { [weak self] desc in
            guard let self, let desc, let kPID = self.kPID else { return }
            let pid = self.number(desc, kPID).map { Int32(truncatingIfNeeded: $0) } ?? 0
            if var flow = self.liveFlows[token] {
                flow.pid = pid
                self.liveFlows[token] = flow
            }
        }
        setCounts(source) { [weak self] counts in
            guard let self, let counts, let kRx = self.kRx, let kTx = self.kTx else { return }
            let total = (self.number(counts, kRx) ?? 0) &+ (self.number(counts, kTx) ?? 0)
            if var flow = self.liveFlows[token] {
                // First count establishes the baseline (so a pre-existing
                // flow's history doesn't count); later counts advance it.
                if flow.baseline == nil { flow.baseline = total }
                flow.latest = total
                self.liveFlows[token] = flow
            }
        }
        // On flow close: retire the bytes seen while we watched it and
        // drop the live entry. Keeps per-pid cumulative monotonic AND
        // bounds `liveFlows` to currently-open flows.
        if let setRemoved {
            setRemoved(source) { [weak self] in
                guard let self, let flow = self.liveFlows.removeValue(forKey: token),
                      flow.pid > 0, let base = flow.baseline, flow.latest >= base else { return }
                self.retired[flow.pid, default: 0] &+= flow.latest - base
            }
        }
    }

    private func number(_ d: CFDictionary, _ k: CFString) -> UInt64? {
        guard let raw = CFDictionaryGetValue(d, unsafeBitCast(k, to: UnsafeRawPointer.self))
        else { return nil }
        var v: Int64 = 0
        return CFNumberGetValue(unsafeBitCast(raw, to: CFNumber.self), .sInt64Type, &v)
            ? UInt64(max(0, v)) : nil
    }
}
