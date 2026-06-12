import Foundation
import Darwin.Mach

// Instantaneous memory snapshot. Three sources combined:
//   • host_statistics64(HOST_VM_INFO64) → vm_statistics64 (page counts)
//   • host_page_size                    → bytes per page
//   • sysctl(VM_SWAPUSAGE)              → xsw_usage (swap used in bytes)
//
// Memory pressure is NOT read by this sampler — the SamplingCoordinator
// polls `kern.memorystatus_vm_pressure_level` once per tick (see
// `refreshPressureLevel` and the rationale comment there) and passes the
// latched level into `toSample(pressure:)`.

public struct MemorySampler: Sampler {
    /// Physical RAM in bytes. Read once from `ProcessInfo.processInfo
    /// .physicalMemory` at sampler init; doesn't change at runtime.
    public let physicalTotalBytes: UInt64

    public init() {
        self.physicalTotalBytes = ProcessInfo.processInfo.physicalMemory
    }

    public func read() throws -> MemoryRaw {
        // -- vm_statistics64 ----------------------------------------------
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &vm) { vmPtr -> kern_return_t in
            vmPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard kr == KERN_SUCCESS else {
            throw SamplerError.mach(kr, op: "host_statistics64(HOST_VM_INFO64)")
        }
        // Page size — `vm_kernel_page_size` is the global; safe to read.
        let pageSize = UInt64(vm_kernel_page_size)
        let activeBytes     = UInt64(vm.active_count)              * pageSize
        let wiredBytes      = UInt64(vm.wire_count)                * pageSize
        let compressedBytes = UInt64(vm.compressor_page_count)     * pageSize
        let freeBytes       = UInt64(vm.free_count)                * pageSize

        // -- swap usage via sysctl ----------------------------------------
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        var mib: [Int32] = [CTL_VM, VM_SWAPUSAGE]
        let rc = sysctl(&mib, u_int(mib.count), &swap, &swapSize, nil, 0)
        guard rc == 0 else {
            throw SamplerError.sysctl(errno: errno, op: "sysctl(VM_SWAPUSAGE)")
        }

        return MemoryRaw(
            activeBytes: activeBytes,
            wiredBytes: wiredBytes,
            compressedBytes: compressedBytes,
            freeBytes: freeBytes,
            physicalTotalBytes: physicalTotalBytes,
            swapUsedBytes: swap.xsu_used
        )
    }
}

// Convert a `MemoryRaw` to a render-ready `MemorySample`. Lives here because
// the conversion is metric-specific (which pages count as "used") rather
// than a generic rate operation.
public extension MemoryRaw {
    /// "Used" memory in the Activity-Monitor sense: active + wired +
    /// compressed. `free` is excluded (idle), and `inactive` is intentionally
    /// not surfaced (it's cache the kernel will reclaim under pressure).
    var usedBytes: UInt64 { activeBytes + wiredBytes + compressedBytes }

    // No default for `pressure` — a silent `.normal` fallback is exactly
    // how the panel shipped a hardcoded pressure value in v1. Callers
    // must state where the level came from.
    func toSample(pressure: MemoryPressure) -> MemorySample {
        MemorySample(
            usedBytes: usedBytes,
            totalBytes: physicalTotalBytes,
            swapUsedBytes: swapUsedBytes,
            pressure: pressure
        )
    }
}
