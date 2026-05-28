import AppKit

/// Lifecycle owner. Builds the metrics store, the sampling coordinator, the
/// status-item controller, and the panel controller; wires them up; starts
/// the idle-tier sampler. Observes system sleep/wake so the next sample
/// after wake is a fresh baseline rather than a multi-hour cross-gap delta.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: MetricsStore?
    private var coordinator: SamplingCoordinator?
    private var statusItemController: StatusItemController?
    private var panelController: PanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = MetricsStore()
        let coordinator = SamplingCoordinator(store: store)
        let panelController = PanelController(store: store, coordinator: coordinator)

        let statusItemController = StatusItemController(store: store) { [weak panelController] in
            panelController?.toggle()
        }
        panelController.bind(statusItem: statusItemController.statusItem)

        self.store = store
        self.coordinator = coordinator
        self.statusItemController = statusItemController
        self.panelController = panelController

        // Re-baseline on wake. macOS's timer suspends during sleep, so the
        // first sample after wake would otherwise compute a delta across
        // the entire sleep duration — yielding garbage like "CPU 4000%".
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        coordinator.startIdleTier()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.shutdown()
    }

    @objc private func systemDidWake() {
        coordinator?.reBaseline()
    }
}
