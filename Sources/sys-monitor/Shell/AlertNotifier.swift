import Foundation
import UserNotifications

/// Posts macOS notifications for fired alerts. A thin main-actor wrapper over
/// `UNUserNotificationCenter`: authorization is requested once at launch, and
/// each fired alert becomes a banner. If the user denied permission, `add`
/// silently no-ops — so there's no need to gate on the grant result.
@MainActor
final class AlertNotifier {
    // `UNUserNotificationCenter.current()` TRAPS when the process has no
    // bundle identifier — true for a bare `.build/debug/sys-monitor` run
    // outside the .app build.sh assembles. Guard on the identifier so dev
    // runs of the raw executable don't crash; the shipped .app
    // (dev.sys-monitor.menubar) has one, so notifications work there.
    private let center: UNUserNotificationCenter? =
        Bundle.main.bundleIdentifier == nil ? nil : .current()

    /// Prompt for notification permission once. Safe to call at launch even
    /// while alerts are disabled — it primes the grant so the first real
    /// alert (after the user enables alerts) isn't swallowed by a prompt.
    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ events: [AlertEvent]) {
        guard let center else { return }
        for e in events {
            let content = UNMutableNotificationContent()
            content.title = e.title
            content.body = e.body
            content.sound = .default
            // Per-kind identifier: a repeat alert of the same kind replaces
            // the prior banner instead of stacking duplicates. nil trigger
            // delivers immediately.
            let req = UNNotificationRequest(
                identifier: "sysmon.alert.\(e.kind.rawValue)",
                content: content, trigger: nil)
            center.add(req)
        }
    }
}
