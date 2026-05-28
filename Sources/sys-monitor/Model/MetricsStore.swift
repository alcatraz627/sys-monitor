import Foundation
import Combine

/// The single source of truth the UI observes.
///
/// `@MainActor` because every consumer (status-item button, SwiftUI views)
/// touches it on main. The sampling coordinator runs on its own background
/// queue and assigns `snapshot` exactly once per tick by hopping to the
/// main actor — see `SamplingCoordinator.publish(_:)`.
@MainActor
public final class MetricsStore: ObservableObject {
    @Published public var snapshot: MetricsSnapshot = .initial()

    public init() {}
}
