import Foundation
import IOKit.ps

/// Battery state from the PUBLIC IOKit power-sources API — no private
/// framework, no entitlement, works from any signed binary. Unlike the
/// IOReport power adapter, this is a sanctioned API, so it needs no
/// degrade-to-unavailable dance beyond "no internal battery present"
/// (a desktop Mac), which the UI treats as "hide the row".
struct BatterySampler {

    /// nil when the machine has no internal battery (desktop) or the
    /// power-sources blob can't be read.
    func read() -> BatterySample? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for src in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
            guard (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }

            // Percent = current/max (IOPS reports both; max is usually 100 but
            // compute it rather than assume).
            let cur = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            let percent = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur

            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let charged  = desc[kIOPSIsChargedKey] as? Bool ?? false
            let onAC     = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue

            // Time fields are minutes; -1 means "still calculating".
            let rawTime = charging ? (desc[kIOPSTimeToFullChargeKey] as? Int)
                                   : (desc[kIOPSTimeToEmptyKey] as? Int)
            let minutesRemaining = (rawTime ?? -1) > 0 ? rawTime : nil

            return BatterySample(percent: percent, charging: charging, charged: charged,
                                 onAC: onAC, minutesRemaining: minutesRemaining)
        }
        return nil
    }
}
