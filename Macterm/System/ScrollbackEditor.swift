import Foundation

/// Builds the shell command that opens a captured scrollback file in the user's
/// editor. Run through the pane's login shell so `$VISUAL`/`$EDITOR` resolve
/// from the user's environment (a GUI-launched app doesn't inherit them), with
/// `vi` as a last resort. `exec` replaces the shell so quitting the editor exits
/// the process and the ephemeral split closes itself.
enum ScrollbackEditor {
    /// e.g. `exec ${VISUAL:-${EDITOR:-vi}} +500 '/tmp/seshterm-scrollback-….txt'`.
    /// `+<line>` opens at that line — passing the last line puts the cursor at
    /// the end (the most recent output). Honored by vi/vim/nvim/nano/emacs;
    /// editors that don't understand `+N` (e.g. Helix, VS Code) just open at the
    /// top.
    static func command(forPath path: String, openAtLine line: Int) -> String {
        "exec ${VISUAL:-${EDITOR:-vi}} +\(max(1, line)) '\(singleQuoteEscaped(path))'"
    }

    /// Escape a path for embedding inside single quotes in a POSIX shell:
    /// close the quote, emit an escaped quote, reopen — `it's` → `it'\''s`.
    /// Temp paths are UUID-based so this is belt-and-suspenders.
    private static func singleQuoteEscaped(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: "'\\''")
    }
}
