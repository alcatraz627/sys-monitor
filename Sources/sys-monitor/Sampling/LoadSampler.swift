import Foundation

/// System load averages and uptime — the classic htop/uptime footer. Load
/// is the count of threads runnable-or-waiting-on-I/O averaged over 1, 5,
/// and 15 minutes; on an N-core machine, ~N means "fully saturated." Both
/// `getloadavg` and `systemUptime` are cheap, so this reads live each sweep.
struct LoadSampler {
    func read() -> LoadAverage? {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return nil }
        return LoadAverage(one: loads[0], five: loads[1], fifteen: loads[2],
                           uptimeSeconds: ProcessInfo.processInfo.systemUptime)
    }
}
