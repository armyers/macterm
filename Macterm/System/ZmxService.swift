import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "ZmxService")

/// Detects the `zmx` session-multiplexer binary and builds the commands Macterm
/// uses to back a pane with a persistent session. zmx owns the shell process in
/// a daemon, so a pane that runs `zmx attach <id>` reattaches to the same live
/// process across an app quit/restart — the editor/REPL keeps running.
///
/// Mirrors `GhosttyCLI`/`ZoxideService`: the candidate paths and executable
/// probe are injected so resolution is unit-testable without touching disk.
struct ZmxService {
    let binaryCandidates: [String]
    /// Filesystem executable probe. Injected so tests don't touch disk.
    let isExecutable: @Sendable (String) -> Bool

    /// The `zmx` binary path, or nil when none is installed.
    func resolveBinary() -> String? {
        binaryCandidates.first(where: isExecutable)
    }

    var isAvailable: Bool { resolveBinary() != nil }

    /// The ghostty `command` a surface runs to attach to `sessionID`, or nil when
    /// zmx isn't installed. An absolute binary path plus arguments; libghostty
    /// runs it via the login shell (`exec -l <command>`), which word-splits it.
    /// (No `direct:` prefix — that's ghostty *config-file* syntax and isn't
    /// understood by the surface-config `command` field.) The id is a UUID, so
    /// there is nothing to shell-expand.
    func attachCommand(sessionID: String) -> String? {
        guard let bin = resolveBinary() else { return nil }
        return "\(bin) attach \(sessionID)"
    }

    /// Permanently end a session — used when the user closes a pane, or to GC
    /// orphaned sessions. App quit must NOT call this: detaching leaves the
    /// session alive to reattach. Fire-and-forget; harmless if absent.
    func kill(sessionID: String, force: Bool = false) {
        var args = ["kill", "--", sessionID]
        if force { args = ["kill", "--force", "--", sessionID] }
        _ = run(args)
    }

    /// Live sessions the daemon knows about (`zmx list`), parsed. Empty when zmx
    /// isn't installed or the daemon isn't running.
    func list() -> [ZmxSession] {
        guard let output = run(["list"]) else { return [] }
        return Self.parseList(output)
    }

    /// The session's scrollback as ANSI (`zmx history <id> --vt`), capped to
    /// roughly the last `maxBytes` so the saved file stays bounded. Headroom over
    /// the replay cap (`SessionResurrect.cappedForReplay`) so capture isn't the
    /// limiting factor. nil on failure.
    ///
    /// Caps by UTF-8 bytes, not lines: `--vt` uses CRLF line endings and Swift
    /// treats `"\r\n"` as one grapheme, so a `split(separator: "\n")` line cap
    /// silently never matches and keeps everything. Trims to the next newline so
    /// the first retained line isn't a partial (which could orphan an SGR escape).
    func history(sessionID: String, maxBytes: Int = 2_621_440) -> String? {
        guard let output = run(["history", sessionID, "--vt"]) else { return nil }
        return Self.tailKeepingBytes(output, maxBytes: maxBytes)
    }

    /// Keep roughly the last `maxBytes` of `text`, trimmed forward to the next
    /// newline so the first retained line isn't a partial (which could orphan an
    /// SGR escape). Returns `text` unchanged when already within budget. Pure.
    static func tailKeepingBytes(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        let bytes = Array(text.utf8)
        var start = bytes.count - maxBytes
        while start < bytes.count, bytes[start] != 0x0A {
            start += 1
        } // 0x0A = '\n'
        if start < bytes.count {
            start += 1 // start just after the newline
        } else {
            start = bytes.count - maxBytes // no newline in the tail; keep the raw tail
        }
        // Lossy decode so a byte-aligned cut that lands mid-codepoint yields
        // U+FFFD rather than dropping the capture (the lint rule prefers the
        // strict failable initializer, which is exactly what we're avoiding).
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: bytes[start...], as: UTF8.self)
    }

    /// Inject `text` into the session's terminal display (`zmx print`), preserving
    /// ANSI/color. Raw bytes, not pty input — doesn't run anything. One IPC
    /// `.Output` message. Stock zmx silently drops a single message in the
    /// ~4-8KB band (the daemon reads one 4096-byte chunk then closes on the
    /// POLLHUP `print` raises by exiting immediately); a patched daemon handles
    /// any size. So callers replaying large scrollback chunk via `chunkOnLines`
    /// (under 4KB) and pace the calls to stay correct on stock zmx (see
    /// `SessionResurrect.seedIfRebooted`).
    func print(sessionID: String, text: String) {
        _ = run(["print", sessionID, text])
    }

    /// Split `text` into pieces of at most ~`maxBytes`, breaking only at line
    /// boundaries so an SGR/escape sequence (always within a line) is never cut.
    /// A single line longer than `maxBytes` is sent whole (rare). Pure/testable.
    ///
    /// Scans at the unicode-scalar level, not by `Character`: replayed scrollback
    /// is CRLF-normalized, and Swift treats `"\r\n"` as a *single* grapheme
    /// cluster — so `Character`-based iteration never sees the `\n` and would
    /// return the whole text as one unsplittable chunk.
    static func chunkOnLines(_ text: String, maxBytes: Int) -> [String] {
        guard text.utf8.count > maxBytes else { return text.isEmpty ? [] : [text] }
        var chunks: [String] = []
        var current = ""
        var currentBytes = 0
        var line = String.UnicodeScalarView()
        /// Emit the accumulated line into `current`, flushing first if it would
        /// overflow the budget — keeping the `\n` attached so the chunks
        /// concatenate back to `text` exactly.
        func emitLine() {
            let s = String(line)
            let bytes = s.utf8.count
            if currentBytes > 0, currentBytes + bytes > maxBytes {
                chunks.append(current)
                current = ""
                currentBytes = 0
            }
            current += s
            currentBytes += bytes
            line = String.UnicodeScalarView()
        }
        for scalar in text.unicodeScalars {
            line.append(scalar)
            if scalar == "\n" { emitLine() }
        }
        if !line.isEmpty { emitLine() }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Send raw input to the session's pty (`zmx send`), as if typed. Used to
    /// re-run the restartable command after a reboot (append `\r` to submit).
    func send(sessionID: String, text: String) {
        _ = run(["send", sessionID, text])
    }

    /// Run `zmx <args>`, returning stdout (nil if zmx is absent or fails to
    /// launch). Used for the read/introspection commands.
    private func run(_ args: [String]) -> String? {
        guard let bin = resolveBinary() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            logger.error("zmx \(args.first ?? "", privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

/// One row of `zmx list`. `isHealthy` is false for the daemon's dead/tombstone
/// entries (`status=unreachable` / `err=…`), which carry no pid.
struct ZmxSession: Equatable {
    let name: String
    let pid: pid_t?
    let startDir: String?
    let clients: Int?
    let isHealthy: Bool
}

extension ZmxService {
    /// Parse `zmx list` output. Each line is TAB-separated `key=value` pairs:
    /// `name=… pid=… clients=… created=… start_dir=…` (plus a trailing `cmd=…`
    /// for sessions started with a command), or for dead sessions
    /// `name=… err=… status=unreachable`. Splitting on TAB (not spaces) keeps a
    /// `start_dir` path with spaces intact and isolates the trailing `cmd`.
    /// Pure — unit-tested.
    static func parseList(_ output: String) -> [ZmxSession] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine -> ZmxSession? in
            var fields: [String: String] = [:]
            for token in rawLine.split(separator: "\t") {
                let t = token.trimmingCharacters(in: .whitespaces)
                guard let eq = t.firstIndex(of: "=") else { continue }
                fields[String(t[..<eq])] = String(t[t.index(after: eq)...])
            }
            guard let name = fields["name"] else { return nil }
            let pid = fields["pid"].flatMap { pid_t($0) }
            let healthy = fields["status"] != "unreachable" && fields["err"] == nil && pid != nil
            return ZmxSession(
                name: name,
                pid: pid,
                startDir: fields["start_dir"],
                clients: fields["clients"].flatMap { Int($0) },
                isHealthy: healthy
            )
        }
    }

    /// The detector Macterm uses at runtime: the common install locations for
    /// Homebrew (Apple Silicon + Intel), MacPorts, and cargo.
    static var standard: ZmxService {
        ZmxService(
            binaryCandidates: [
                "/opt/homebrew/bin/zmx",
                "/usr/local/bin/zmx",
                "/opt/local/bin/zmx",
                NSHomeDirectory() + "/.cargo/bin/zmx",
            ],
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }
        )
    }
}

/// How a pane's surface should be launched, resolved from the session-persistence
/// setting + zmx availability. Pure/testable; `Pane.ensureNSView` wires the live
/// inputs and passes the result to `GhosttyTerminalNSView`.
struct PaneLaunch: Equatable {
    /// Full ghostty `command` (e.g. a `direct:zmx attach …` line) the surface
    /// runs as its program; nil → fall back to the default shell resolution.
    let program: String?
    /// Shell path to run when `program` is nil (the native path).
    let shell: String?
    /// Command typed into the pty after spawn — the native re-run seed.
    let initialInput: String?

    /// - Parameter attachCommand: the zmx attach command for this pane, or nil
    ///   when zmx isn't backing it (persistence off or zmx not installed).
    static func resolve(attachCommand: String?, command: String?, shell: String?) -> PaneLaunch {
        if let attachCommand {
            // zmx-backed: run the attach command. The live session carries its
            // own process state, so there's no shell fallback or re-run seed.
            return PaneLaunch(program: attachCommand, shell: nil, initialInput: nil)
        }
        // Native: run the (optional) shell and re-run the recorded command.
        return PaneLaunch(program: nil, shell: shell, initialInput: command)
    }
}
