import Foundation

/// Decides which foreground commands are worth re-launching when a session is
/// restored after a reboot (tmux-resurrect / zellij style). Most processes
/// can't be meaningfully resumed, so only a curated allowlist of programs that
/// re-open cleanly with the same arguments — editors, pagers, viewers, and
/// monitors — are restarted; everything else restores as a plain shell.
enum RestartableCommand {
    /// Program names (argv[0] basename, lowercased) safe to re-launch with their
    /// original arguments. Hardcoded for now; could become a user setting later.
    static let allowlist: Set<String> = [
        // editors
        "vi", "vim", "nvim", "hx", "helix", "nano", "emacs", "emacsclient",
        "micro", "kak", "kakoune", "ne", "vis",
        // pagers / viewers
        "less", "more", "most", "bat", "man", "tig", "delta",
        // monitors / TUIs that resume fine
        "top", "htop", "btop", "btm", "glances", "lazygit", "lazydocker", "k9s",
    ]

    /// The command to re-launch on restore, or nil when it shouldn't be: nil
    /// input, or a program not in `allowlist`. Matches on the basename of the
    /// first whitespace-separated token (so `/usr/bin/vi file` → `vi`).
    static func restartable(_ command: String?) -> String? {
        guard let command,
              let first = command.split(separator: " ", maxSplits: 1).first
        else { return nil }
        let program = (String(first) as NSString).lastPathComponent.lowercased()
        return allowlist.contains(program) ? command : nil
    }
}
