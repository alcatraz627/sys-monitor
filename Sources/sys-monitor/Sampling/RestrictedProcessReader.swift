import Foundation

/// Fills in the processes this app is not allowed to inspect itself:
/// WindowServer, launchd, Spotlight's indexers and every other daemon that
/// runs as root or as a system user. They are often the answer to "what is
/// slowing this machine down", and without them the process list can only
/// ever name the user's own apps.
///
/// The kernel refuses this app's requests for those processes, but `/bin/ps`
/// is installed setuid root and may read them, so one `ps` call per process
/// sweep supplies their CPU time and resident memory. Measured at 30 ms of
/// wall time per call on a machine with about 1,070 processes; the sweep runs
/// every other tick and only while the panel is open.
///
/// What `ps` cannot give is disk bytes, energy or the memory footprint
/// Activity Monitor shows. `SystemFootprintReader` supplies the footprint from
/// `top`; disk and energy stay unknown, and the rows are marked `isRestricted`
/// for the panel to say so.
struct RestrictedProcessReader {

    /// Every process `ps` can see whose pid is not in `known`. Returns an
    /// empty list if `ps` cannot be run, which leaves the list as it was
    /// before this reader existed.
    func read(excluding known: Set<Int32>,
              footprints: [Int32: UInt64] = [:]) -> [ProcRaw] {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        // -c prints the bare executable name instead of its full path.
        ps.arguments = ["-Axco", "pid=,ppid=,time=,rss=,comm="]
        let out = Pipe()
        ps.standardOutput = out
        ps.standardError = FileHandle.nullDevice
        do { try ps.run() } catch { return [] }
        // Drain before waiting: the listing is larger than a pipe buffer, so
        // waiting first would leave ps blocked on a full pipe forever.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        guard ps.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return [] }
        return Self.parse(text, excluding: known, footprints: footprints)
    }

    /// Turn `ps` output into raw readings, skipping pids in `known` and any
    /// line that does not parse. A pid found in `footprints` carries that as
    /// its memory; the rest fall back to the resident size `ps` reports.
    static func parse(_ text: String, excluding known: Set<Int32>,
                      footprints: [Int32: UInt64] = [:]) -> [ProcRaw] {
        var result: [ProcRaw] = []
        for line in text.split(separator: "\n") {
            // The name is last and may contain spaces, so only the first four
            // columns are split off.
            let cols = line.split(separator: " ", maxSplits: 4,
                                  omittingEmptySubsequences: true)
            guard cols.count == 5,
                  let pid = Int32(cols[0]), pid > 0, !known.contains(pid),
                  let ppid = Int32(cols[1]),
                  let cpuNs = cpuTimeNs(String(cols[2])),
                  let rssKB = UInt64(cols[3]) else { continue }
            result.append(ProcRaw(
                pid: pid,
                ppid: ppid,
                name: cols[4].trimmingCharacters(in: .whitespaces),
                cpuTimeNs: cpuNs,
                residentBytes: rssKB * 1024,
                footprintBytes: footprints[pid] ?? 0,
                diskBytes: 0,
                energyNanojoules: 0,
                isRestricted: true
            ))
        }
        return result
    }

    /// Read the memory column `top` prints, such as `1336M`, `8096K+` or
    /// `2G-`, into bytes. The trailing sign only says which way it moved.
    static func topMemoryBytes(_ s: String) -> UInt64? {
        var digits = Substring(s)
        while let last = digits.last, last == "+" || last == "-" { digits.removeLast() }
        guard let unit = digits.last else { return nil }
        let scale: Double
        switch unit {
        case "B": scale = 1
        case "K": scale = 1024
        case "M": scale = 1_048_576
        case "G": scale = 1_073_741_824
        default:  return nil
        }
        guard let n = Double(digits.dropLast()), n >= 0 else { return nil }
        return UInt64(n * scale)
    }

    /// Turn `top -stats pid,mem` output into memory per pid, ignoring the
    /// summary lines above the table.
    static func parseTopMemory(_ text: String) -> [Int32: UInt64] {
        var out: [Int32: UInt64] = [:]
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count == 2, let pid = Int32(cols[0]),
                  let bytes = topMemoryBytes(String(cols[1])) else { continue }
            out[pid] = bytes
        }
        return out
    }

    /// Parse the cumulative CPU time `ps` prints, such as `464:21.60`,
    /// `1:02:03.50` or `2-03:04:05`, into nanoseconds.
    static func cpuTimeNs(_ s: String) -> UInt64? {
        var days = 0.0
        var rest = Substring(s)
        if let dash = rest.firstIndex(of: "-") {
            guard let d = Double(rest[..<dash]) else { return nil }
            days = d
            rest = rest[rest.index(after: dash)...]
        }
        let parts = rest.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.count <= 3,
              !parts.contains(where: { $0 == nil }) else { return nil }
        // Seconds are last; each field to the left is worth 60 of the one
        // after it.
        var seconds = 0.0
        for p in parts { seconds = seconds * 60 + (p ?? 0) }
        seconds += days * 86_400
        guard seconds >= 0 else { return nil }
        return UInt64(seconds * 1_000_000_000)
    }
}

/// The real memory use of system processes, which `ps` cannot report.
///
/// `ps` gives resident size, and for a process like WindowServer that is a
/// quarter of what Activity Monitor shows (338 MB against 1.4 GB, measured).
/// `top` reports the same footprint Activity Monitor does, for every process,
/// but one listing costs about 0.7 s of CPU. So it is read in the background,
/// at most once a minute, and only when something asks for it; callers get the
/// last result at once and never wait on `top`.
final class SystemFootprintReader: @unchecked Sendable {
    private let lock = NSLock()
    private var footprints: [Int32: UInt64] = [:]
    private var lastStarted: TimeInterval = 0
    private var refreshing = false
    private let queue = DispatchQueue(label: "sys-monitor.footprints", qos: .utility)

    /// The latest footprints by pid, starting a background refresh if they
    /// are more than `maxAge` seconds old. Empty until the first refresh lands.
    func current(now: TimeInterval, maxAge: TimeInterval = 60) -> [Int32: UInt64] {
        lock.lock()
        let cached = footprints
        let due = !refreshing && (lastStarted == 0 || now - lastStarted > maxAge)
        if due { refreshing = true; lastStarted = now }
        lock.unlock()
        if due {
            queue.async { [weak self] in
                let fresh = Self.read()
                guard let self else { return }
                self.lock.lock()
                // A failed read keeps the previous figures rather than
                // dropping every system process back to resident size.
                if !fresh.isEmpty { self.footprints = fresh }
                self.refreshing = false
                self.lock.unlock()
            }
        }
        return cached
    }

    /// One `top` listing of memory per pid. Empty if `top` cannot be run.
    static func read() -> [Int32: UInt64] {
        let top = Process()
        top.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        top.arguments = ["-l", "1", "-stats", "pid,mem"]
        let out = Pipe()
        top.standardOutput = out
        top.standardError = FileHandle.nullDevice
        do { try top.run() } catch { return [:] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        top.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        return RestrictedProcessReader.parseTopMemory(text)
    }
}
