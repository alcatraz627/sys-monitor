import Foundation

/// The presentation state of one metric in a snapshot.
///
/// `measuring` — the metric is alive but the first valid value isn't ready
/// yet (rate metrics need two samples; a sleep/wake gap can also drop us
/// back to this). UI shows `—`.
///
/// `ok(T)` — a real value, including legitimate zero (e.g. swap 0 GB on a
/// machine with plenty of RAM). UI shows the value as-is.
///
/// `unavailable` — the sampler errored, the metric isn't readable on this
/// machine, or we explicitly demoted it. UI shows `—`. Distinct from
/// `measuring` because there's no recovery path expected.
public enum Metric<T> {
    case measuring
    case ok(T)
    case unavailable
}

extension Metric: Sendable where T: Sendable {}
extension Metric: Equatable where T: Equatable {}
