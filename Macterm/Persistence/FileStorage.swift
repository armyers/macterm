import Foundation

enum FileStorage {
    static func fileURL(filename: String) -> URL {
        appSupportDirectory().appendingPathComponent(filename)
    }

    static func appSupportDirectory() -> URL {
        // The benchmark harness (scripts/benchmark.py) points this at a
        // throwaway directory so a benchmark run can't read or pollute the
        // real app data. An env override is required because
        // `.applicationSupportDirectory` resolves via the user record, not
        // `$HOME` — a temp `$HOME` doesn't isolate it.
        if let benchDir = ProcessInfo.processInfo.environment["MACTERM_BENCHMARK_DATA_DIR"],
           !benchDir.isEmpty
        {
            let dir = URL(fileURLWithPath: benchDir, isDirectory: true)
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return dir
        }
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
        else {
            fatalError("Application Support directory unavailable")
        }
        let dir = appSupport.appendingPathComponent(appDisplayName, isDirectory: true)
        // Before creating the (empty) dir, inherit data from the pre-rebrand
        // "Macterm" dir if this is the first launch under the new name.
        migrateLegacyDataIfNeeded(appSupport: appSupport, into: dir)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir
    }

    /// One-time copy of the previous "Macterm"(-flavored) Application Support
    /// directory into the current one, so the rebranded app (Seshterm) inherits
    /// the contexts/projects/settings the old name accumulated. The legacy name
    /// is the current display name with "Seshterm" → "Macterm" (so "Seshterm" ←
    /// "Macterm", "Seshterm Debug" ← "Macterm Debug"). No-op once the current
    /// dir exists, when the legacy dir is absent, or for the upstream name.
    private static func migrateLegacyDataIfNeeded(appSupport: URL, into currentDir: URL) {
        let legacyName = appDisplayName.replacingOccurrences(of: "Seshterm", with: "Macterm")
        guard legacyName != appDisplayName else { return }
        let fm = FileManager.default
        let legacyDir = appSupport.appendingPathComponent(legacyName, isDirectory: true)
        guard !fm.fileExists(atPath: currentDir.path), fm.fileExists(atPath: legacyDir.path) else { return }
        try? fm.copyItem(at: legacyDir, to: currentDir)
    }
}
