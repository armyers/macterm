import Foundation

/// On-disk store of per-session scrollback captures (ANSI `--vt` from
/// `zmx history`), used to replay color scrollback when a session is
/// resurrected after a reboot. One file per zmx sessionID under
/// `Application Support/<app>/scrollback/`. sessionIDs are UUIDs, so they're
/// safe filenames.
enum ResurrectStore {
    private static var directory: URL {
        let dir = FileStorage.appSupportDirectory().appendingPathComponent("scrollback", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir
    }

    static func fileURL(sessionID: String) -> URL {
        directory.appendingPathComponent("\(sessionID).vt")
    }

    static func write(sessionID: String, scrollback: String) {
        try? Data(scrollback.utf8).write(to: fileURL(sessionID: sessionID), options: .atomic)
    }

    static func scrollback(sessionID: String) -> String? {
        // Lossy UTF-8: a `--vt` dump can carry a stray non-UTF-8 byte (e.g. Latin-1
        // in `ls` output), and a strict decode would throw and nil the *entire*
        // replay. Decode lossily so one bad byte can't drop the whole scrollback.
        guard let data = try? Data(contentsOf: fileURL(sessionID: sessionID)) else { return nil }
        // The lint rule prefers the failable `String(bytes:encoding:)`, but that's
        // the strict decode we're deliberately avoiding here — `String(decoding:)`
        // substitutes U+FFFD for bad bytes instead of nilling the whole replay.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: data, as: UTF8.self)
    }

    /// Delete scrollback files whose session is no longer referenced, keeping the
    /// directory bounded as panes/sessions come and go.
    static func prune(keeping liveSessionIDs: Set<String>) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "vt" {
            let id = file.deletingPathExtension().lastPathComponent
            if !liveSessionIDs.contains(id) { try? fm.removeItem(at: file) }
        }
    }
}
