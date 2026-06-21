import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "DirectorySearch")

/// Finds directories for the context picker without Finder: zoxide (frecency,
/// visited dirs) first, then a depth-limited `fd` walk under a search root for
/// directories you haven't visited yet. Results are de-duplicated, zoxide-first.
///
/// Mirrors `GhosttyCLI`/`ZoxideService`: binary candidates and the executable
/// probe are injected so the merge logic is unit-testable without spawning.
struct DirectorySearch {
    let zoxide: ZoxideService
    /// Candidate absolute paths to the `fd` binary, highest priority first.
    let fdCandidates: [String]
    /// Filesystem executable probe. Injected so tests don't touch disk.
    let isExecutable: @Sendable (String) -> Bool
    /// Root directory for the `fd` walk.
    let searchRoot: String
    /// Max depth for the `fd` walk (keeps the per-keystroke walk bounded).
    let maxDepth: Int

    /// The `fd` binary path, or nil when none is installed (zoxide-only then).
    func resolveFd() -> String? {
        fdCandidates.first(where: isExecutable)
    }

    /// Matching directories, frecency-ranked first (zoxide) then filesystem
    /// matches (`fd`) not already surfaced. Both lookups run concurrently and
    /// off the main thread; empty when nothing matches.
    func search(keywords: [String], limit: Int = 10) async -> [String] {
        guard !keywords.isEmpty else { return [] }
        async let zoxideDirs = zoxide.query(keywords: keywords, limit: limit)
        async let fdDirs = fdSearch(keywords: keywords, limit: limit * 2)
        let (z, f) = await (zoxideDirs, fdDirs)
        let merged = Self.merge(zoxide: z, filesystem: f, limit: limit)
        logger.info("dir search '\(keywords.joined(separator: " "), privacy: .public)': \(merged.count, privacy: .public) dirs")
        return merged
    }

    /// zoxide results first, then filesystem dirs not already present, capped at
    /// `limit`. Pure — unit-tested.
    static func merge(zoxide: [String], filesystem: [String], limit: Int) -> [String] {
        var seen = Set(zoxide)
        var out = zoxide
        for dir in filesystem where seen.insert(dir).inserted {
            out.append(dir)
        }
        return Array(out.prefix(limit))
    }

    private func fdSearch(keywords: [String], limit: Int) async -> [String] {
        guard let fd = resolveFd() else { return [] }
        // Join keywords with `.*` so a multi-word query stays a loose substring
        // match against directory names (fd treats the pattern as a regex).
        let pattern = keywords.joined(separator: ".*")
        let root = searchRoot
        let depth = maxDepth
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let raw = Self.runFd(fd: fd, pattern: pattern, root: root, maxDepth: depth)
                let dirs = Array(
                    raw
                        .split(separator: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                        .prefix(limit)
                )
                continuation.resume(returning: dirs)
            }
        }
    }

    private static func runFd(fd: String, pattern: String, root: String, maxDepth: Int) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: fd)
        process.arguments = [
            "--type", "directory",
            "--max-depth", String(maxDepth),
            "--color", "never",
            pattern, root,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            logger.error("fd launch failed at \(fd, privacy: .public): \(String(describing: error), privacy: .public)")
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return "" }
        return output
    }
}

extension DirectorySearch {
    /// `~/code` if it exists, else the home directory — the root for the `fd`
    /// walk and the historical default for new contexts.
    static var defaultSearchRoot: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let code = home.appendingPathComponent("code", isDirectory: true)
        let codePath = code.path(percentEncoded: false)
        return FileManager.default.fileExists(atPath: codePath) ? codePath : home.path(percentEncoded: false)
    }

    /// The detector Macterm uses at runtime: zoxide + the common `fd` install
    /// locations (Homebrew, MacPorts, cargo), walking `defaultSearchRoot`.
    static var standard: DirectorySearch {
        DirectorySearch(
            zoxide: .standard,
            fdCandidates: [
                "/opt/homebrew/bin/fd",
                "/usr/local/bin/fd",
                "/opt/local/bin/fd",
                NSHomeDirectory() + "/.cargo/bin/fd",
            ],
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            searchRoot: defaultSearchRoot,
            maxDepth: 6
        )
    }
}
