import Foundation
import IOKit
import os

/// Per-cluster CPU frequency (MHz) on Apple Silicon, sudoless — the same
/// signal `powermetrics` reports as "HW active frequency", derived from
/// the PRIVATE IOReport performance-state residency counters weighted by
/// the per-cluster DVFS frequency table read from IORegistry.
///
/// Held to the same adapter contract as PowerMonitor: every symbol resolved
/// at runtime, ANY failure (or ANY ambiguity that could mislabel a cluster)
/// degrades to "unavailable" and the UI shows nothing. The cluster→table
/// mapping is unlabeled and chip-specific, so the safe rule is: match a
/// residency channel to a DVFS table by state count, accept it only when
/// exactly one distinct table has that count, and only keep tables whose
/// values normalize into a plausible CPU-frequency range. A chip we can't
/// map cleanly shows no frequency rather than a wrong one.
///
/// IOReport exposes cumulative residency (time-in-state); we diff two
/// samples so the weighting reflects the interval, not all of uptime — the
/// standard dual-sample pattern. First `read()` after start returns nil.
///
/// ⚠️ NOT YET PANEL-READY (v2.1 #69). The DVFS table parsing is validated
/// against `powermetrics` (see SelfTest), but the residency→frequency
/// *alignment* is not: the residency channels carry ~2 idle/down states the
/// freq table omits, and their position (front vs back) differs per channel —
/// the 17-state P-cluster aligns correctly, the 22-state S-cluster does not
/// (it reads LOW under load). So this is reachable only via `--probe-freq`
/// for validation; do NOT wire a panel row until `--probe-freq` reconciles
/// with `powermetrics` for every cluster. Full notes:
/// `.claude/output/20260615-ioreport-probe/10.1-freq-spike-findings.md`.
final class FrequencyMonitor: @unchecked Sendable {

    private(set) var isAvailable = false

    private let queue = DispatchQueue(label: "sys-monitor.frequency")
    private let log = Logger(subsystem: "dev.sys-monitor.menubar", category: "frequency")

    private typealias CopyAllT = @convention(c) (UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubT = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> Unmanaged<AnyObject>?
    private typealias CreateSamplesT = @convention(c) (AnyObject, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateDeltaT = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias ChStrT = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias StateCountT = @convention(c) (CFDictionary) -> Int32
    private typealias StateResidencyT = @convention(c) (CFDictionary, Int32) -> Int64

    private var createSamples: CreateSamplesT?
    private var createDelta: CreateDeltaT?
    private var getGroup: ChStrT?
    private var getSubGroup: ChStrT?
    private var getName: ChStrT?
    private var stateCount: StateCountT?
    private var stateResidency: StateResidencyT?

    private var channels: CFMutableDictionary?
    private var subscription: AnyObject?
    private var prevSample: CFDictionary?

    /// DVFS frequency tables (MHz) keyed by state count, ONLY for counts that
    /// resolve to a single distinct table — the ambiguity guard. Cached once.
    private var tablesByCount: [Int: [Double]] = [:]

    /// The IOReport subgroup that carries per-cluster residency. "CPU Complex
    /// Performance States" is the per-cluster (not per-core) view.
    private let complexSubgroup = "CPU Complex Performance States"

    init() { queue.sync { self.setup() } }

    func resetBaseline() { queue.async { [weak self] in self?.prevSample = nil } }

    /// Per-cluster residency-weighted frequency, or nil until a baseline
    /// exists / when unavailable. `now` is unused (residency is its own clock)
    /// but kept for call-site symmetry with the other monitors.
    func read() -> [ClusterFrequency]? {
        queue.sync {
            guard isAvailable, let channels, let sub = subscription,
                  let createSamples, let createDelta,
                  let getGroup, let getName, let stateCount, let stateResidency
            else { return nil }

            guard let curU = createSamples(sub, channels, nil) else { return nil }
            let cur = curU.takeRetainedValue()
            defer { prevSample = cur }
            guard let prev = prevSample, let deltaU = createDelta(prev, cur, nil) else { return nil }
            let delta = deltaU.takeRetainedValue()
            guard let d = delta as? [String: Any], let chans = d["IOReportChannels"] as? [Any] else { return nil }

            var out: [ClusterFrequency] = []
            for c in chans {
                guard let nd = c as? NSDictionary else { continue }
                let cd = nd as CFDictionary
                guard (getGroup(cd)?.takeUnretainedValue() as String?) == "CPU Stats" else { continue }
                guard (getSubGroup?(cd)?.takeUnretainedValue() as String?) == complexSubgroup else { continue }

                let n = Int(stateCount(cd))
                // The residency channel carries the DVFS freq states plus a
                // small number (k) of idle/down states the freq table omits —
                // powermetrics reports those separately. Match the table whose
                // entry count T leaves a small, unique offset k = n - T, and
                // align the table to the channel's last T states (the leading
                // k are the idle/down buckets, weighted at ~0 = skipped).
                guard let table = Self.matchTable(stateCount: n, tablesByCount: tablesByCount) else { continue }
                let k = n - table.count

                var weighted = 0.0, total = 0.0
                for i in 0..<table.count {
                    let r = Double(stateResidency(cd, Int32(k + i)))
                    guard r > 0 else { continue }
                    weighted += table[i] * r
                    total += r
                }
                guard total > 0 else { continue }   // cluster idle this interval
                let name = getName(cd)?.takeUnretainedValue() as String? ?? "cpu"
                out.append(ClusterFrequency(name: name, mhz: weighted / total))
            }
            return out.isEmpty ? nil : out.sorted { $0.name < $1.name }
        }
    }

    // MARK: - Setup

    private func setup() {
        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return }
        func fn<T>(_ name: String, _ t: T.Type) -> T? {
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
            let sc = fn("IOReportStateGetCount", StateCountT.self),
            let sr = fn("IOReportStateGetResidency", StateResidencyT.self)
        else {
            log.info("frequency unavailable: IOReport symbols missing")
            return
        }
        let gsg = fn("IOReportChannelGetSubGroup", ChStrT.self)   // optional; without it we can't filter the subgroup
        guard gsg != nil else { log.info("frequency unavailable: no subgroup accessor"); return }

        // DVFS tables first — if we can't parse any, there's nothing to map.
        let tables = Self.cpuFrequencyTables()
        guard !tables.isEmpty else { log.info("frequency unavailable: no DVFS tables"); return }
        self.tablesByCount = Self.uniqueByCount(tables)
        guard !tablesByCount.isEmpty else { log.info("frequency unavailable: DVFS tables all ambiguous"); return }

        guard let chanU = copyAll(0, 0) else { return }
        let chan = chanU.takeRetainedValue()
        var subbed: Unmanaged<CFMutableDictionary>? = nil
        guard let subU = createSub(nil, chan, &subbed, 0, nil) else { return }

        self.createSamples = cs; self.createDelta = cd
        self.getGroup = gg; self.getSubGroup = gsg; self.getName = gn
        self.stateCount = sc; self.stateResidency = sr
        self.channels = chan
        self.subscription = subU.takeRetainedValue()
        self.isAvailable = true
        log.info("frequency available — \(self.tablesByCount.count) DVFS table(s) mapped")
    }

    // MARK: - IORegistry DVFS table parsing

    /// All `voltage-states*` blobs from the `pmgr` node decoded as MHz tables,
    /// keeping only those that look like real CPU frequency curves.
    static func cpuFrequencyTables() -> [[Double]] {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        var iter = io_iterator_t()
        guard IORegistryEntryCreateIterator(root, kIODeviceTreePlane,
              IOOptionBits(kIORegistryIterateRecursively), &iter) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }

        var tables: [[Double]] = []
        var entry = IOIteratorNext(iter)
        while entry != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any] {
                for (k, v) in dict where k.lowercased().hasPrefix("voltage-states") {
                    guard let data = v as? Data, let mhz = decodeTable(data) else { continue }
                    tables.append(mhz)
                }
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iter)
        }
        return tables
    }

    /// Decode a `(freq, voltage)` u32-pair blob to MHz, auto-detecting the
    /// freq unit, and accept it only if it reads like a CPU DVFS curve:
    /// ≥4 points, non-decreasing, all within 200…6000 MHz, top > 1000 MHz.
    /// Returns nil for the voltage-only / period tables that share the prefix.
    static func decodeTable(_ data: Data) -> [Double]? {
        let pairs = data.count / 8
        guard pairs >= 4 else { return nil }
        var raw: [UInt32] = []
        data.withUnsafeBytes { buf in
            let u32 = buf.bindMemory(to: UInt32.self)
            for i in 0..<pairs { raw.append(UInt32(littleEndian: u32[i * 2])) }
        }
        // Pick the divisor (Hz or kHz) that lands the max in CPU range.
        for divisor in [1_000_000.0, 1_000.0] {
            let mhz = raw.map { Double($0) / divisor }
            guard let lo = mhz.first, let hi = mhz.last else { continue }
            let nonDecreasing = zip(mhz, mhz.dropFirst()).allSatisfy { $0 <= $1 + 0.001 }
            if nonDecreasing && lo >= 200 && hi <= 6000 && hi > 1000 { return mhz }
        }
        return nil
    }

    /// Pick the DVFS table for a residency channel of `stateCount` states.
    /// The channel = T freq states + k idle/down states, so look for a table
    /// whose count T gives a small offset k = stateCount - T (0…3), and take
    /// it only if exactly one table count fits (so we never mis-map). Prefers
    /// the smallest offset.
    static func matchTable(stateCount n: Int, tablesByCount: [Int: [Double]]) -> [Double]? {
        var hits: [(k: Int, table: [Double])] = []
        for k in 0...3 where tablesByCount[n - k] != nil {
            hits.append((k, tablesByCount[n - k]!))
        }
        guard hits.count == 1 else { return nil }   // 0 or ambiguous → no map
        return hits[0].table
    }

    /// Index tables by entry count, keeping a count ONLY when every table with
    /// that count is identical (so the by-count match is unambiguous).
    static func uniqueByCount(_ tables: [[Double]]) -> [Int: [Double]] {
        var byCount: [Int: [[Double]]] = [:]
        for t in tables { byCount[t.count, default: []].append(t) }
        var out: [Int: [Double]] = [:]
        for (count, group) in byCount {
            let first = group[0]
            let allIdentical = group.allSatisfy { $0.count == first.count && zip($0, first).allSatisfy { abs($0 - $1) < 0.001 } }
            if allIdentical { out[count] = first }   // ambiguous counts dropped
        }
        return out
    }
}
