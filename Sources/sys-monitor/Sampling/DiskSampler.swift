import Foundation
import IOKit

// IOBlockStorageDriver statistics-dictionary keys. These exist in
// <IOKit/storage/IOBlockStorageDriver.h> as `#define` string macros and so
// don't bridge into Swift as named constants — we use the macro VALUES
// directly. (Standard workaround used by every IOKit-storage Swift project.)
private let kStorageStatistics       = "Statistics"
private let kStorageStatisticsRead   = "Bytes (Read)"
private let kStorageStatisticsWrite  = "Bytes (Write)"

// IOKit-based disk-I/O sampler. PROVISIONAL per N8 / R6 — the API exists on
// every Mac but its reliability on Apple-Silicon + APFS-over-NVMe is the
// documented sharp edge. The Phase-1 spike runs this sampler once, records
// the result (driver count + plausible byte counts), and the user decides
// whether to commit the disk row or demote it to v2.
//
// If the spike fails, `DiskSampler.isUsable` flips to `false`, callers wrap
// `read()` in a guard, and `NetDiskRow` hides the disk side (never `—/—`).

public struct DiskSampler: Sampler {
    public init() {}

    public func read() throws -> DiskCounters {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOBlockStorageDriver")
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard kr == KERN_SUCCESS else {
            throw SamplerError.ioKit(op: "IOServiceGetMatchingServices(IOBlockStorageDriver)")
        }
        defer { IOObjectRelease(iterator) }

        var totalRead: UInt64 = 0
        var totalWrite: UInt64 = 0
        var driverCount = 0

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            driverCount += 1
            guard let stats = IORegistryEntryCreateCFProperty(
                service,
                kStorageStatistics as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any] else {
                continue
            }
            if let r = stats[kStorageStatisticsRead] as? NSNumber {
                totalRead &+= r.uint64Value
            }
            if let w = stats[kStorageStatisticsWrite] as? NSNumber {
                totalWrite &+= w.uint64Value
            }
        }

        if driverCount == 0 {
            throw SamplerError.unavailable(reason: "no IOBlockStorageDriver nodes found")
        }
        return DiskCounters(
            readBytes: totalRead,
            writeBytes: totalWrite,
            driverCount: driverCount
        )
    }
}
