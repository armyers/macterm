import Darwin
import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "SessionResurrect")

/// Seconds-since-epoch of the last system boot (`kern.boottime`). Constant for a
/// machine's uptime and changes on every reboot, so comparing a value stored at
/// save time to the current one tells us whether the machine rebooted since —
/// i.e. whether the zmx daemon (and thus every persisted session) survived.
enum SystemBootTime {
    static func current() -> Int? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return nil }
        return Int(tv.tv_sec)
    }
}

/// Post-reboot restore ("resurrect") of zmx-backed panes.
///
/// On an app quit the daemon survives, so `zmx attach <id>` reattaches to the
/// still-live session — scrollback and the running process are intact, nothing
/// to do. On a reboot the daemon is gone, so that same attach creates a *fresh*
/// login shell; we then seed it from the snapshot: replay the saved color
/// scrollback (the shell's persistent context), then re-run the restartable
/// program on top — so quitting the program drops back into the shell with its
/// history, exactly like tmux-resurrect.
@MainActor
enum SessionResurrect {
    /// Whether the machine rebooted since the workspace was last saved. Set once
    /// at launch (see `AppState.restoreSelection`); when false, restored sessions
    /// are live and never seeded.
    static var didReboot = false

    /// Seed a freshly-created post-reboot session for `sessionID`. No-op unless
    /// we rebooted, persistence is on, zmx is available, and there's something to
    /// replay. Fire-and-forget from `Pane.ensureNSView` after the attach; all zmx
    /// subprocess work runs off the main thread, so it never blocks the UI.
    static func seedIfRebooted(sessionID: String, command: String?) {
        guard didReboot, Preferences.shared.sessionPersistenceEnabled, ZmxService.standard.isAvailable else { return }
        let scrollback = ResurrectStore.scrollback(sessionID: sessionID)
        guard scrollback != nil || command != nil else { return }
        Task.detached(priority: .utility) {
            let zmx = ZmxService.standard
            // Wait for our own attach to bring the fresh session up (bounded).
            var ready = false
            for _ in 0 ..< 20 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if zmx.list().contains(where: { $0.name == sessionID && $0.isHealthy }) {
                    ready = true
                    break
                }
            }
            guard ready else {
                logger.error("resurrect seed timed out waiting for session \(sessionID, privacy: .public)")
                return
            }
            // Let the login shell draw its first prompt before injecting.
            try? await Task.sleep(nanoseconds: 300_000_000)
            if let scrollback, !scrollback.isEmpty {
                zmx.print(sessionID: sessionID, text: cappedForReplay(scrollback))
            }
            if let command, !command.isEmpty {
                zmx.send(sessionID: sessionID, text: command + "\r")
            }
            logger.info("resurrected session \(sessionID, privacy: .public)")
        }
    }

    /// Trim replayed scrollback to roughly the last `maxBytes`, so it stays well
    /// under `ARG_MAX` when passed to `zmx print`. Keeps the most recent *whole*
    /// lines within the budget — never cutting mid-line (which would split a
    /// color escape) or mid-codepoint.
    nonisolated static func cappedForReplay(_ vt: String, maxBytes: Int = 64 * 1024) -> String {
        guard vt.utf8.count > maxBytes else { return vt }
        var kept: [Substring] = []
        var total = 0
        for line in vt.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            total += line.utf8.count + 1 // + the newline join
            if total > maxBytes { break }
            kept.append(line)
        }
        return kept.reversed().joined(separator: "\n")
    }
}
