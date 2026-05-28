import Foundation
import Darwin.Mach

// Overall + per-core CPU counters via mach `host_statistics` and
// `host_processor_info`. Tick counters are cumulative; the coordinator
// deltas them against the prior sample (RateMath.cpuUtilization).
//
// MANDATORY hygiene (docs/03-implementation.md §5.1, review issue 4):
//   • Use `mach_host_self()` for the host port (it's a borrowed name; do
//     not deallocate it).
//   • Every successful `host_processor_info` returns an array allocated by
//     the kernel — we MUST `vm_deallocate(mach_task_self_, addr, byteSize)`
//     it after copying, where `byteSize = count * MemoryLayout<integer_t>
//     .stride`. Skipping this leaks a mach VM region per open tick and
//     blows NFR-4 over a long-running session.

public struct CPUSampler: Sampler {
    public init() {}

    public func read() throws -> CPUCounters {
        let host = mach_host_self()
        let overall = try readOverall(host: host)
        let perCore = try readPerCore(host: host)
        return CPUCounters(overall: overall, perCore: perCore)
    }

    // MARK: - Overall

    private func readOverall(host: mach_port_t) throws -> CPUTicks {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &info) { infoPtr -> kern_return_t in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                host_statistics(host, HOST_CPU_LOAD_INFO, reboundPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else {
            throw SamplerError.mach(kr, op: "host_statistics(HOST_CPU_LOAD_INFO)")
        }
        return CPUTicks(
            user:   UInt32(bitPattern: Int32(info.cpu_ticks.0)),
            system: UInt32(bitPattern: Int32(info.cpu_ticks.1)),
            idle:   UInt32(bitPattern: Int32(info.cpu_ticks.2)),
            nice:   UInt32(bitPattern: Int32(info.cpu_ticks.3))
        )
    }

    // MARK: - Per-core

    private func readPerCore(host: mach_port_t) throws -> [CPUTicks] {
        var cpuCount: natural_t = 0
        var infoArray: processor_info_array_t? = nil
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(
            host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &infoArray, &infoCount
        )
        guard kr == KERN_SUCCESS, let info = infoArray else {
            throw SamplerError.mach(kr, op: "host_processor_info(PROCESSOR_CPU_LOAD_INFO)")
        }
        // Always deallocate the kernel-allocated array (NFR-4 leak guard).
        // The byte size is `infoCount * stride(of: integer_t)` — `infoCount`
        // is in `integer_t` units, not bytes.
        defer {
            let byteSize = vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            let addr = vm_address_t(UInt(bitPattern: info))
            vm_deallocate(mach_task_self_, addr, byteSize)
        }

        // PROCESSOR_CPU_LOAD_INFO returns CPU_STATE_MAX ints per core, in
        // the order [USER, SYSTEM, IDLE, NICE].
        let perCoreStride = Int(CPU_STATE_MAX)
        var result: [CPUTicks] = []
        result.reserveCapacity(Int(cpuCount))
        for i in 0..<Int(cpuCount) {
            let base = i * perCoreStride
            result.append(CPUTicks(
                user:   UInt32(bitPattern: Int32(info[base + Int(CPU_STATE_USER)])),
                system: UInt32(bitPattern: Int32(info[base + Int(CPU_STATE_SYSTEM)])),
                idle:   UInt32(bitPattern: Int32(info[base + Int(CPU_STATE_IDLE)])),
                nice:   UInt32(bitPattern: Int32(info[base + Int(CPU_STATE_NICE)]))
            ))
        }
        return result
    }
}
