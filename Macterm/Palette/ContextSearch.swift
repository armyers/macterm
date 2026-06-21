import Foundation

/// Pure ranking for the context picker (the name-first task switcher behind
/// `cmd+shift+p`). Kept out of the view so it's unit-testable like the palette
/// sources. Reuses `fuzzyScore` from `PaletteEngine`.
enum ContextSearch {
    struct Result {
        /// Existing contexts matching the query, best match first.
        let matches: [Project]
        /// Whether to offer a "Create context '<query>'" row. True only when the
        /// query is non-empty and doesn't exactly (case-insensitively) name an
        /// existing context — selecting that one would open it, not create.
        let showCreateRow: Bool
    }

    /// - Parameters:
    ///   - query: the raw search text.
    ///   - projects: all known contexts.
    ///   - recent: recent contexts, most-recent-first, shown when the query is empty.
    static func search(query: String, projects: [Project], recent: [Project]) -> Result {
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        guard !trimmed.isEmpty else {
            return Result(matches: recent, showCreateRow: false)
        }

        let matches = projects
            .compactMap { project -> (Project, Int)? in
                let nameScore = fuzzyScore(query: trimmed, target: project.name)
                let pathScore = fuzzyScore(query: trimmed, target: project.path)
                guard let best = [nameScore, pathScore].compactMap(\.self).min() else { return nil }
                return (project, best)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)

        let hasExactName = projects.contains {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }

        return Result(matches: matches, showCreateRow: !hasExactName)
    }
}
