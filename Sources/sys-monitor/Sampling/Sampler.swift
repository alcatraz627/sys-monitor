import Foundation

// Shared protocol + error type for the per-metric samplers under
// Sources/sys-monitor/Sampling/. Each sampler returns a RAW reading (a
// `Sendable` value); the SamplingCoordinator owns delta → rate conversion
// against measured elapsed wall-clock time.

public protocol Sampler {
    associatedtype Reading: Sendable
    /// Snapshot the metric right now. Cheap, synchronous, off-main. Throws
    /// `SamplerError` on failure; the coordinator surfaces failures as
    /// `Metric.unavailable` per FR-17 (never crashes, never blanks the panel).
    func read() throws -> Reading
}

/// What can go wrong inside a sampler. Carries enough context to be useful
/// in a log line; the user-facing surface just sees `—` per FR-17.
public enum SamplerError: Error, CustomStringConvertible, Sendable {
    case mach(kern_return_t, op: String)
    case sysctl(errno: Int32, op: String)
    case ioKit(op: String)
    case unavailable(reason: String)

    public var description: String {
        switch self {
        case let .mach(kr, op):       return "mach error \(kr) during \(op)"
        case let .sysctl(errno, op):  return "sysctl errno \(errno) during \(op)"
        case let .ioKit(op):          return "IOKit failure during \(op)"
        case let .unavailable(reason): return "unavailable: \(reason)"
        }
    }
}
