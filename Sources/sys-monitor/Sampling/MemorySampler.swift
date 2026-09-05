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
        let activeBytes      = UInt64(vm.active_count)              * pageSize
        let wiredBytes       = UInt64(vm.wire_count)                * pageSize
        let compressedBytes  = UInt64(vm.compressor_page_count)     * pageSize
        let freeBytes        = UInt64(vm.free_count)                * pageSize
        let inactiveBytes    = UInt64(vm.inactive_count)            * pageSize
        let internalBytes    = UInt64(vm.internal_page_count)       * pageSize
        let externalBytes    = UInt64(vm.external_page_count)       * pageSize
        let purgeableBytes   = UInt64(vm.purgeable_count)           * pageSize
        let speculativeBytes = UInt64(vm.speculative_count)         * pageSize

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
            inactiveBytes: inactiveBytes,
            internalBytes: internalBytes,
            externalBytes: externalBytes,
            purgeableBytes: purgeableBytes,
            speculativeBytes: speculativeBytes,
            physicalTotalBytes: physicalTotalBytes,
            swapUsedBytes: swap.xsu_used
        )
    }
}

// Convert a `MemoryRaw` to a render-ready `MemorySample`. Lives here because
// the conversion is metric-specific (which pages count as "used") rather
// than a generic rate operation.
public extension MemoryRaw {
    /// App memory: anonymous pages minus the purgeable ones the kernel may
    /// drop without paging.
    var appBytes: UInt64 { internalBytes >= purgeableBytes ? internalBytes - purgeableBytes : 0 }

    /// "Used" memory in the Activity-Monitor sense: app + wired + compressed.
    ///
    /// It was `active + wired + compressed` until 2026-09-06, which is a
    /// page-queue size rather than a measure of what is allocated. XNU
    /// balances the active and inactive queues, so `active` carries file
    /// cache that happens to be active and omits app pages aged to inactive.
    /// Measured, a 6 GiB anonymous allocation moved Activity Monitor by
    /// 5.97 GiB and moved the old formula by 0.08 GiB, because the
    /// allocation displaced file cache inside queues whose totals held
    /// steady. Heavy file reads pushed it the other way.
    var usedBytes: UInt64 { appBytes + wiredBytes + compressedBytes }

    /// Activity Monitor's "Cached Files".
    var cachedFilesBytes: UInt64 { externalBytes + purgeableBytes }

    /// `vm_stat`'s notion of free, which excludes pages read ahead but not
    /// yet faulted. The raw `free_count` counts those.
    var trulyFreeBytes: UInt64 {
        freeBytes >= speculativeBytes ? freeBytes - speculativeBytes : 0
    }

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
