import AppKit
import Combine
import ServiceManagement

/// Lifecycle owner. Builds the metrics store, the settings store, the
/// sampling coordinator, the status-item + panel + settings-window
/// controllers; wires settings change observers to every reader site;
/// observes system sleep so the next sample after wake re-baselines
/// instead of computing a multi-hour cross-gap delta.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: SettingsStore?
    private var store: MetricsStore?
    private var coordinator: SamplingCoordinator?
    private var statusItemController: StatusItemController?
    private var panelController: PanelController?
    private var settingsWindowController: SettingsWindowController?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = SettingsStore()
        let store = MetricsStore()

        let coordinator = SamplingCoordinator(
            store: store,
            idleCadenceSeconds: settings.idleCadenceSeconds,
            openCadenceSeconds: settings.openCadenceSeconds
        )

        let panelController = PanelController(
            store: store, settings: settings, coordinator: coordinator
        )

        let settingsWindow = SettingsWindowController(settings: settings) {
            [weak panelController] in panelController?.close()
        }
        panelController.onShowSettings = { [weak settingsWindow] in
            settingsWindow?.show()
        }

        let statusItemController = StatusItemController(
            store: store,
            style: GlyphRenderer.Style(settings.barStyle)
        ) { [weak panelController] in
            panelController?.toggle()
        }
        panelController.bind(statusItem: statusItemController.statusItem)

        self.settings = settings
        self.store = store
        self.coordinator = coordinator
        self.statusItemController = statusItemController
        self.panelController = panelController
        self.settingsWindowController = settingsWindow

        // Live-apply settings changes. Each `dropFirst()` skips Combine's
        // replay of the current value at subscription time so we only react
        // to genuine user-driven changes.
        settings.$idleCadenceSeconds.dropFirst()
            .sink { [weak coordinator] s in coordinator?.updateIdleCadenceSeconds(s) }
            .store(in: &cancellables)

        settings.$openCadenceSeconds.dropFirst()
            .sink { [weak coordinator] s in coordinator?.updateOpenCadenceSeconds(s) }
            .store(in: &cancellables)

        settings.$barStyle.dropFirst()
            .sink { [weak statusItemController] s in
                statusItemController?.updateStyle(GlyphRenderer.Style(s))
            }
            .store(in: &cancellables)

        settings.$launchAtLogin.dropFirst()
            .sink { enabled in
                Self.applyLaunchAtLogin(enabled, settings: settings)
            }
            .store(in: &cancellables)

        // Read current login-item status so the settings UI shows truth,
        // not just intent, on first paint.
        Self.refreshLaunchAtLoginStatus(settings: settings)

        // Re-baseline on wake — the timer is suspended during sleep, so
        // the first post-wake sample would otherwise compute deltas across
        // the entire sleep duration.
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

    // MARK: - Launch at login

    private static func applyLaunchAtLogin(_ enabled: Bool, settings: SettingsStore) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else       { try SMAppService.mainApp.unregister() }
        } catch {
            settings.setLaunchAtLoginStatus("error: \(error.localizedDescription)")
            return
        }
        refreshLaunchAtLoginStatus(settings: settings)
    }

    private static func refreshLaunchAtLoginStatus(settings: SettingsStore) {
        let label: String
        switch SMAppService.mainApp.status {
        case .enabled:          label = "enabled"
        case .notRegistered:    label = "not registered"
        case .notFound:         label = "not found (move .app to ~/Applications)"
        case .requiresApproval: label = "requires approval in System Settings"
        @unknown default:       label = "unknown"
        }
        settings.setLaunchAtLoginStatus(label)
    }
}

// Bridge between the persisted Settings enum and the renderer's enum.
// Kept here rather than inside GlyphRenderer to avoid the shell depending
// on the Settings type — the bridge is a one-line conversion.
private extension GlyphRenderer.Style {
    init(_ s: SettingsStore.BarStyle) {
        switch s {
        case .cpuPercent:    self = .cpuPercent
        case .memoryPercent: self = .memoryPercent
        }
    }
}
