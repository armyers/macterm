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

    /// Permanently end a session — used when the user closes a pane. App quit
    /// must NOT call this: detaching leaves the session alive to reattach.
    /// Fire-and-forget; harmless if the session doesn't exist.
    func kill(sessionID: String) {
        guard let bin = resolveBinary() else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = ["kill", sessionID]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger.error("zmx kill failed at \(bin, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}

extension ZmxService {
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
