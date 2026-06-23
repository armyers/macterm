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
/// login shell; we then seed it from the snapshot: replay the saved scrollback
/// (the shell's persistent context, captured in-process via the surface's
/// `read_text` — plain text for now; color is a follow-up), then re-run the
/// restartable program on top — so quitting the program drops back into the
/// shell with its history, like tmux-resurrect.
@MainActor
enum SessionResurrect {
    /// Whether the machine rebooted since the workspace was last saved. Set once
    /// at launch (see `AppState.restoreSelection`); when false, restored sessions
    /// are live and never seeded.
    static var didReboot = false

    /// Seed a freshly-created post-reboot session: once the fresh shell has
    /// settled at its prompt, replay the saved scrollback with `zmx print` —
    /// which streams into the live attached client (the pane) and renders, the
    /// channel that demonstrably works (the resume-script `cat` ran inside the
    /// session before the client was rendering, so it never appeared) — then
    /// re-run the restartable command on top. No-op unless we rebooted,
    /// persistence is on, zmx is available, and there's something to replay.
    /// Fire-and-forget from `ensureNSView`; all zmx work runs off the main thread.
    static func seedIfRebooted(sessionID: String, command: String?) {
        guard didReboot, Preferences.shared.sessionPersistenceEnabled, ZmxService.standard.isAvailable else { return }
        // `read_text` pads with trailing blank rows; trim before capping so the
        // tail-cap keeps real content. CRLF-normalize so it doesn't staircase.
        let scrollback = ResurrectStore.scrollback(sessionID: sessionID)
            .map { cappedForReplay(sanitizeForReplay(trimTrailingBlankLines($0))) }
            .flatMap { $0.isEmpty ? nil : $0 }
        guard scrollback != nil || command?.isEmpty == false else { return }
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
                debugLog("SEED \(sessionID.prefix(8)): TIMED OUT waiting for session")
                return
            }
            debugLog("SEED \(sessionID.prefix(8)): appeared, scrollback=\(scrollback?.utf8.count ?? 0)B command=\(command ?? "nil")")
            // Wait for the login shell to settle at its prompt — scrollback goes
            // non-empty and stops growing — so the client is rendering and our
            // injected bytes aren't dropped or wiped by the prompt redraw.
            var lastLen = -1
            for _ in 0 ..< 30 {
                try? await Task.sleep(nanoseconds: 300_000_000)
                let len = zmx.history(sessionID: sessionID)?.count ?? 0
                if len > 0, len == lastLen { break }
                lastLen = len
            }
            if let scrollback {
                // zmx renders a single print only up to ~4KB, and drops replays
                // beyond ~50KB total when sent back-to-back. So chunk under 4KB
                // (cappedForReplay already bounds the total to ~48KB) and pace
                // the calls so the client keeps up.
                let chunks = ZmxService.chunkOnLines(scrollback, maxBytes: 3000)
                for chunk in chunks {
                    zmx.print(sessionID: sessionID, text: chunk)
                    try? await Task.sleep(nanoseconds: 25_000_000)
                }
                logger.notice("resurrect print \(sessionID, privacy: .public): \(chunks.count, privacy: .public) chunks")
                debugLog("PRINT \(sessionID.prefix(8)): \(scrollback.utf8.count) bytes in \(chunks.count) chunks")
            } else {
                debugLog("PRINT \(sessionID.prefix(8)): no scrollback to replay")
            }
            if let command, !command.isEmpty {
                try? await Task.sleep(nanoseconds: 200_000_000)
                zmx.send(sessionID: sessionID, text: command + "\r")
                debugLog("SEND \(sessionID.prefix(8)): \(command)")
            }
            logger.notice("resurrected session \(sessionID, privacy: .public)")
        }
    }

    /// Append a line to the temp debug log, only while the `forceReboot` test
    /// key is set. os_log isn't persisted for the signed build, so this is the
    /// reliable channel for observing the seed during testing.
    nonisolated static func debugLog(_ message: String) {
        guard UserDefaults.standard.bool(forKey: "macterm.resurrect.forceReboot") else { return }
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "seshterm-restore-debug.log")
        let line = Data((message + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    /// Normalize captured scrollback for replay: keep SGR color sequences,
    /// printable text, and newlines; drop cursor moves, erases, DEC private
    /// modes, and OSC; normalize every CR / LF / CRLF to an explicit CRLF.
    /// Scrollback now comes from `read_text` (plain text), so the escape-
    /// stripping is mostly defensive — but it stays correct if a future styled
    /// `read_text` emits SGR, and the CRLF normalization is what fixes the
    /// "staircase" when the text is `cat` into the pre-shell pty (no ONLCR).
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
    /// Drop trailing blank / whitespace-only lines. `ghostty_surface_read_text`
    /// returns the whole screen region, so the live screen's empty rows below the
    /// prompt come through as blank trailing lines; replaying them would push the
    /// real history off-screen (and defeat the tail-based cap).
    nonisolated static func trimTrailingBlankLines(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    nonisolated static func cappedForReplay(_ vt: String, maxBytes: Int = 48 * 1024) -> String {
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
