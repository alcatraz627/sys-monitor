import Foundation
import Darwin

/// Enumerates running processes and reads cumulative CPU time + resident
/// size for each. Uses `proc_listpids` (two-call sizing) then a single
/// `proc_pidinfo(PROC_PIDTASKINFO)` per PID — `pti_total_user +
/// pti_total_system` is the canonical CPU-time pair and lives in
/// nanoseconds, so the coordinator can delta straight against wall-clock
/// elapsed seconds.
///
/// `proc_pid_rusage` is NOT used — it overlaps `PROC_PIDTASKINFO` for the
/// fields we need and would double the syscall count of what's already the
/// most expensive sampler.
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
            result.append(ProcRaw(
                pid: pid,
                name: name,
                cpuTimeNs: cpuTimeNs,
                residentBytes: info.pti_resident_size
            ))
        }
        return result
    }
}
