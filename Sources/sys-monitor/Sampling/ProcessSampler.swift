import Foundation
import Darwin

/// Enumerates running processes and reads cumulative CPU time + resident
/// size for each. Uses `proc_listpids` (two-call sizing) then a single
/// `proc_pidinfo(PROC_PIDTASKINFO)` per PID — `pti_total_user +
/// pti_total_system` is the canonical CPU-time pair and lives in
/// nanoseconds, so the coordinator can delta straight against wall-clock
/// elapsed seconds.
///
/// `proc_pid_rusage` IS used (once per PID) for the cumulative disk-I/O bytes
/// that feed the per-process disk rate — there is no `PROC_PIDTASKINFO` field
/// for that. It roughly doubles this sampler's syscall count, which is the
/// main reason process sampling runs ONLY on the open tier and only every
/// 2nd tick. (An earlier version avoided rusage entirely; the per-process
/// disk I/O feature reintroduced it. See docs/11-perf-audit.md finding #1 for
/// a deferral that would skip it for non-displayed PIDs under a CPU sort.)
///
/// Per-process memory is `pti_resident_size` (RSS), NOT `phys_footprint`:
/// rusage (and thus footprint) is privilege-denied for other users' PIDs,
/// so RSS is the one memory metric available consistently for ALL processes
/// sudoless. RSS reads higher than Activity Monitor's "Memory" (footprint);
/// the self-cost readout uses footprint instead since our own PID can always
/// read it (see PanelRootView.currentProcessFootprintBytes).
///
/// Vanished / privilege-denied PIDs are simply skipped (the `proc_pidinfo`
/// race between listing and reading is normal on a busy system; skipping
/// is the documented fix, not retrying).
public struct ProcessSampler: Sampler {
    public init() {}

    public func read() throws -> [ProcRaw] {
        // Size probe — passing NULL buffer with 0 size returns the number
        // of bytes needed to hold every PID.
        let neededBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard neededBytes > 0 else {
            throw SamplerError.unavailable(reason: "proc_listpids size probe failed")
        }
        let capacity = Int(neededBytes) / MemoryLayout<pid_t>.stride
        var pids = [pid_t](repeating: 0, count: capacity)
        let written = pids.withUnsafeMutableBufferPointer { buf -> Int32 in
            proc_listpids(
                UInt32(PROC_ALL_PIDS), 0,
                buf.baseAddress,
                Int32(buf.count * MemoryLayout<pid_t>.stride)
            )
        }
        guard written > 0 else {
            throw SamplerError.unavailable(reason: "proc_listpids fetch failed")
        }
        let validCount = Int(written) / MemoryLayout<pid_t>.stride

        var result: [ProcRaw] = []
        result.reserveCapacity(validCount)

        for i in 0..<validCount {
            let pid = pids[i]
            if pid <= 0 { continue }   // kernel placeholder (pid 0)

            var info = proc_taskinfo()
            let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
                proc_pidinfo(
                    pid, PROC_PIDTASKINFO, 0,
                    ptr, Int32(MemoryLayout<proc_taskinfo>.size)
                )
            }
            // rc == 0 typically means the PID vanished between listing and
            // querying; rc < 0 means permission denied. Both are "skip,
            // don't error" per the unavailable-PID contract.
            if rc <= 0 { continue }

            // Name via proc_name — returns the short "comm" name (up to
            // about 16 chars on macOS). Empty-name fallback to "[pid N]"
            // is handled in the UI, not here.
            var nameBuf = [CChar](repeating: 0, count: 256)
            let nameLen = nameBuf.withUnsafeMutableBufferPointer { buf -> Int32 in
                proc_name(pid, buf.baseAddress, UInt32(buf.count))
            }
            let name: String = (nameLen > 0) ? String(cString: nameBuf) : ""

            let cpuTimeNs = info.pti_total_user &+ info.pti_total_system

            // Lifetime disk bytes via rusage — feeds the per-process disk
            // rate. Denied (other-user) pids report 0 and simply rank at
            // the bottom of a disk sort; that's the honest floor without
            // root.
            var usage = rusage_info_current()
            let gotUsage = withUnsafeMutablePointer(to: &usage) { ptr -> Bool in
                ptr.withMemoryRebound(to: (rusage_info_t?).self, capacity: 1) { reb in
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, reb) == 0
                }
            }
            let diskBytes = gotUsage
                ? usage.ri_diskio_bytesread &+ usage.ri_diskio_byteswritten
                : 0

            result.append(ProcRaw(
                pid: pid,
                name: name,
                cpuTimeNs: cpuTimeNs,
                residentBytes: info.pti_resident_size,
                diskBytes: diskBytes
            ))
        }
        return result
    }
}
