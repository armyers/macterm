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

    /// For a dead (post-reboot) session, a `zmx attach` *command* that paints the
    /// saved scrollback before starting the login shell, or nil to fall back to a
    /// plain attach (no saved scrollback, or anything went wrong).
    ///
    /// We do NOT inject scrollback with `zmx print` into a live shell: that lands
    /// after the prompt (misformatted) and is clobbered by full-screen programs'
    /// alternate-screen save/restore (so quitting `vi` showed nothing). Instead
    /// the fresh session runs a tiny resume script — `cat <scrollback>; exec
    /// $SHELL -l` — so the scrollback renders at the top of a clean screen and
    /// the shell's prompt comes up beneath it, surviving alt-screen programs.
    ///
    /// The script and a sanitized scrollback file are written to the (space-free)
    /// temp dir so the attach command word-splits cleanly in libghostty. Returns
    /// `"<base> /bin/sh <scriptPath>"`. Called on the main thread from
    /// `ensureNSView` (tiny synchronous writes).
    nonisolated static func resumeAttachCommand(base: String, sessionID: String) -> String? {
        guard let raw = ResurrectStore.scrollback(sessionID: sessionID) else { return nil }
        let clean = cappedForReplay(sanitizeForReplay(raw))
        guard !clean.isEmpty else { return nil }
        let dir = NSTemporaryDirectory()
        let sbPath = dir + "seshterm-sb-\(sessionID).vt"
        let scriptPath = dir + "seshterm-resume-\(sessionID).sh"
        // The attach command is word-split on spaces by libghostty, so the script
        // path must be space-free; bail to a plain attach if the temp dir isn't.
        guard !scriptPath.contains(" ") else { return nil }
        let script = "cat '\(sbPath)' 2>/dev/null\nexec \"${SHELL:-/bin/zsh}\" -l\n"
        do {
            try clean.write(toFile: sbPath, atomically: true, encoding: .utf8)
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        } catch {
            logger.error("resume script write failed for \(sessionID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        logger.info("resume attach for \(sessionID, privacy: .public): \(clean.utf8.count, privacy: .public) bytes scrollback")
        return "\(base) /bin/sh \(scriptPath)"
    }

    /// Re-run the restartable command in a freshly-resurrected session. Scrollback
    /// is handled by `resumeAttachCommand`; this only sends the command, once the
    /// shell has settled at its prompt. No-op unless we rebooted, persistence is
    /// on, zmx is available, and there's a command. Fire-and-forget; off-main.
    static func seedCommandIfRebooted(sessionID: String, command: String?) {
        guard didReboot, Preferences.shared.sessionPersistenceEnabled, ZmxService.standard.isAvailable,
              let command, !command.isEmpty
        else { return }
        Task.detached(priority: .utility) {
            let zmx = ZmxService.standard
            // Wait for our own attach to create the fresh session (patient —
            // background-tab panes attach well after launch).
            var appeared = false
            for _ in 0 ..< 40 {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if zmx.list().contains(where: { $0.name == sessionID && $0.isHealthy }) {
                    appeared = true
                    break
                }
            }
            guard appeared else {
                logger.error("resurrect seed timed out waiting for session \(sessionID, privacy: .public)")
                return
            }
            // Wait for the login shell to settle at its prompt before sending —
            // a too-early write is dropped. Readiness proxy: the session's
            // scrollback goes non-empty (resume script's cat output, then prompt)
            // and stops growing between reads.
            var lastLen = -1
            for _ in 0 ..< 30 {
                try? await Task.sleep(nanoseconds: 300_000_000)
                let len = zmx.history(sessionID: sessionID)?.count ?? 0
                if len > 0, len == lastLen { break }
                lastLen = len
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            zmx.send(sessionID: sessionID, text: command + "\r")
            logger.info("resurrected session \(sessionID, privacy: .public)")
        }
    }

    /// Strip a captured `zmx history --vt` dump down to what's safe to *replay*
    /// as scrollback: SGR color sequences, printable text, and newlines. The
    /// dump is a screen snapshot — it carries absolute cursor moves, erases, DEC
    /// private modes (e.g. bracketed paste), and OSC that, replayed via `print`,
    /// reposition and overwrite rather than append, so nothing readable lands
    /// (the cause of "scrollback not restored"). Keeping only SGR + text turns it
    /// into clean colored lines; CR / CRLF are normalized to LF.
    nonisolated static func sanitizeForReplay(_ vt: String) -> String {
        let s = Array(vt.unicodeScalars)
        let n = s.count
        var out = String.UnicodeScalarView()
        var i = 0
        func isFinal(_ u: UnicodeScalar) -> Bool {
            u.value >= 0x40 && u.value <= 0x7E
        }
        while i < n {
            let c = s[i]
            if c.value == 0x1B { // ESC
                if i + 1 < n, s[i + 1] == "[" { // CSI — keep only SGR (`…m`)
                    var j = i + 2
                    while j < n, !isFinal(s[j]) {
                        j += 1
                    }
                    if j < n {
                        if s[j] == "m" { for k in i ... j {
                            out.append(s[k])
                        } }
                        i = j + 1
                    } else {
                        i = n
                    }
                    continue
                } else if i + 1 < n, s[i + 1] == "]" { // OSC — drop to BEL / ST
                    var j = i + 2
                    while j < n {
                        if s[j].value == 0x07 { j += 1
                            break
                        }
                        if s[j].value == 0x1B, j + 1 < n, s[j + 1] == "\\" { j += 2
                            break
                        }
                        j += 1
                    }
                    i = j
                    continue
                } else { // other escape — drop ESC + the next byte
                    i += 2
                    continue
                }
            } else if c == "\r" || c == "\n" {
                // Normalize CR / LF / CRLF to an explicit CRLF. The replayed text
                // is `cat`'d into the fresh session before the shell sets up the
                // tty, where there's no ONLCR translation — bare LF would move
                // down without returning to column 0 (the "staircase" bug).
                out.append("\r")
                out.append("\n")
                if c == "\r", i + 1 < n, s[i + 1] == "\n" { i += 2 } // consume CRLF pair
                else { i += 1 }
                continue
            } else {
                out.append(c)
                i += 1
            }
        }
        return String(out)
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
