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
/// Activity Monitor shows, so those rows carry resident memory and are marked
/// `isRestricted` for the panel to say so.
struct RestrictedProcessReader {

    /// Every process `ps` can see whose pid is not in `known`. Returns an
    /// empty list if `ps` cannot be run, which leaves the list as it was
    /// before this reader existed.
    func read(excluding known: Set<Int32>) -> [ProcRaw] {
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
        return Self.parse(text, excluding: known)
    }

    /// Turn `ps` output into raw readings, skipping pids in `known` and any
    /// line that does not parse.
    static func parse(_ text: String, excluding known: Set<Int32>) -> [ProcRaw] {
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
                footprintBytes: 0,
                diskBytes: 0,
                energyNanojoules: 0,
                isRestricted: true
            ))
        }
        return result
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
