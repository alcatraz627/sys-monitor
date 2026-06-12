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
    private var testHookSource: DispatchSourceSignal?

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
            cells: settings.barCells.ordered,
            activityArrows: settings.arrowActivityIndicator,
            onClick: { [weak panelController] in
                panelController?.toggle()
            },
            onShowSettings: { [weak settingsWindow] in
                settingsWindow?.show()
            }
        )
        panelController.bind(statusItem: statusItemController.statusItem)

        // Idle-tier samplers track the bar cells: if NET / DISK is shown
        // there, we need samples to compute its rate while the panel's
        // closed.
        coordinator.configureIdleSamplers(
            net:  settings.barCells.contains(.net),
            disk: settings.barCells.contains(.disk)
        )

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

        settings.$barCells.dropFirst()
            .sink { [weak statusItemController, weak coordinator, weak settings] cells in
                statusItemController?.updateCells(
                    cells.ordered,
                    activityArrows: settings?.arrowActivityIndicator ?? true
                )
                coordinator?.configureIdleSamplers(
                    net:  cells.contains(.net),
                    disk: cells.contains(.disk)
                )
            }
            .store(in: &cancellables)

        settings.$arrowActivityIndicator.dropFirst()
            .sink { [weak statusItemController, weak settings] on in
                statusItemController?.updateCells(
                    settings?.barCells.ordered ?? [.cpu, .mem],
                    activityArrows: on
                )
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

        // Pause sampling whenever nobody can see the widget: display
        // sleep (NSWorkspace) and screen lock (distributed notification —
        // there is no public NSWorkspace equivalent). Both paths are
        // idempotent in the coordinator, so a lock that also sleeps the
        // display suspends once and resumes once.
        let wsCenter = NSWorkspace.shared.notificationCenter
        wsCenter.addObserver(self, selector: #selector(displayWentDark),
                             name: NSWorkspace.screensDidSleepNotification, object: nil)
        wsCenter.addObserver(self, selector: #selector(displayCameBack),
                             name: NSWorkspace.screensDidWakeNotification, object: nil)
        let distCenter = DistributedNotificationCenter.default()
        distCenter.addObserver(self, selector: #selector(displayWentDark),
                               name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        distCenter.addObserver(self, selector: #selector(displayCameBack),
                               name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)

        // Accessory apps have no visible menu bar, but key equivalents
        // still route through NSApp.mainMenu — without this hidden Edit
        // menu, Cmd+A / C / V / X / Z are dead in every text field the
        // app shows (the panel's filter, settings fields).
        installHiddenEditMenu()

        coordinator.startIdleTier()

        // Headless test hook: `SYSMON_TEST_HOOKS=1` + SIGUSR1 toggles the
        // panel, letting verification drills exercise open/close paths
        // (tier transitions, open latency) without a mouse. Off unless
        // the env var is set, so a stray signal can't pop the panel in
        // normal use.
        if ProcessInfo.processInfo.environment["SYSMON_TEST_HOOKS"] == "1" {
            signal(SIGUSR1, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
            src.setEventHandler { [weak panelController] in
                panelController?.toggle()
            }
            src.resume()
            testHookSource = src
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.shutdown()
    }

    @objc private func systemDidWake() {
        coordinator?.reBaseline()
    }

    private func installHiddenEditMenu() {
        let mainMenu = NSMenu()
        let editHolder = NSMenuItem()
        mainMenu.addItem(editHolder)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editHolder.submenu = edit
        NSApp.mainMenu = mainMenu
    }

    @objc private func displayWentDark() {
        panelController?.close()
        coordinator?.suspendForDisplaySleep()
    }

    @objc private func displayCameBack() {
        coordinator?.resumeFromDisplaySleep()
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

