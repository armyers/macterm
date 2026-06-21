import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "ZoxideService")

/// Looks up directories from the user's zoxide database (frecency-ranked) so the
/// context picker can find a folder by a fragment of its name — no Finder, no
/// Spotlight. Degrades to no results when zoxide isn't installed.
///
/// Mirrors `GhosttyCLI`: the candidate binary paths and the executable probe are
/// injected so the selection/parsing logic is unit-testable without touching
/// disk or spawning a process.
struct ZoxideService {
    /// Candidate absolute paths to the `zoxide` binary, highest priority first.
    let binaryCandidates: [String]
    /// Filesystem executable probe. Injected so tests don't touch disk.
    /// `@Sendable` so the service stays `Sendable` for use across `query`'s
    /// background hop under strict concurrency.
    let isExecutable: @Sendable (String) -> Bool

    /// The `zoxide` binary path, or nil when none is installed.
    func resolveBinary() -> String? {
        binaryCandidates.first(where: isExecutable)
    }

    /// Query the database for directories matching `keywords`, frecency-ranked.
    /// Runs the subprocess off the main thread. Returns at most `limit` existing
    /// directories; empty when zoxide is missing or nothing matches.
    func query(keywords: [String], limit: Int = 8) async -> [String] {
        guard !keywords.isEmpty else { return [] }
        let joined = keywords.joined(separator: " ")
        guard let binary = resolveBinary() else {
            logger.notice("zoxide skipped '\(joined, privacy: .public)': no binary found")
            return []
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let raw = Self.run(binary: binary, keywords: keywords)
                let dirs = Self.parse(output: raw, limit: limit) { path in
                    var isDir: ObjCBool = false
                    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
                }
                logger.info("zoxide '\(joined, privacy: .public)': \(dirs.count, privacy: .public) dirs")
                continuation.resume(returning: dirs)
            }
        }
    }

    /// Parse `zoxide query -l` output (one absolute path per line): trim blanks,
    /// keep only existing directories, cap at `limit`. Pure — `isDir` is injected.
    static func parse(output: String, limit: Int, isDir: (String) -> Bool) -> [String] {
        Array(
            output
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && isDir($0) }
                .prefix(limit)
        )
    }

    private static func run(binary: String, keywords: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["query", "-l"] + keywords
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            logger.error("zoxide launch failed at \(binary, privacy: .public): \(String(describing: error), privacy: .public)")
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8)
        else { return "" }
        return output
    }
}

extension ZoxideService {
    /// The detector Macterm uses at runtime: probes the common install locations
    /// for Homebrew (Apple Silicon + Intel), MacPorts, cargo, and Nix.
    static var standard: ZoxideService {
        ZoxideService(
            binaryCandidates: [
                "/opt/homebrew/bin/zoxide",
                "/usr/local/bin/zoxide",
                "/opt/local/bin/zoxide",
                NSHomeDirectory() + "/.cargo/bin/zoxide",
                "/run/current-system/sw/bin/zoxide",
            ],
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }
        )
    }
}
