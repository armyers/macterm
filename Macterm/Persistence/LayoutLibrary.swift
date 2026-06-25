import Foundation

/// A named, reusable layout template in the library. `file` is the same
/// `LayoutFile` format as a project's `.macterm/layout.yaml`, with its `name`
/// (project) field left nil — a template isn't tied to one project.
struct LayoutTemplate: Identifiable, Equatable {
    /// Display name; also the file stem under the library directory.
    let name: String
    let file: LayoutFile
    var id: String { name }
}

enum LayoutLibraryError: LocalizedError {
    case noActiveWorkspace

    var errorDescription: String? {
        switch self {
        case .noActiveWorkspace: "There's no active workspace to save."
        }
    }
}

/// Global library of reusable layout templates, stored as YAML under
/// `Application Support/<app>/layouts/<name>.yaml`. A template is chosen when
/// creating a new context to seed its initial workspace (applied once via
/// `LayoutReconciler`), and authored either by "Save Workspace as Layout…" or by
/// dropping a YAML file in the directory. Built-in starters are seeded once.
///
/// The directory is injected (default: the app-support `layouts` dir) so tests
/// run against a tempdir and never touch real Application Support.
struct LayoutLibrary {
    let directory: URL

    static var standard: LayoutLibrary {
        LayoutLibrary(directory: FileStorage.appSupportDirectory().appendingPathComponent("layouts", isDirectory: true))
    }

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func url(forName name: String) -> URL {
        directory.appendingPathComponent("\(Self.sanitized(name)).yaml")
    }

    /// Filesystem-safe file stem: replace path separators / colons, trim. Keeps
    /// spaces and case so the display name reads naturally.
    static func sanitized(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// All templates (parseable ones only), sorted by name case-insensitively.
    func list() -> [LayoutTemplate] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        else { return [] }
        return files
            .filter { $0.pathExtension == "yaml" }
            .compactMap { fileURL -> LayoutTemplate? in
                guard let text = try? String(contentsOf: fileURL, encoding: .utf8),
                      let file = try? LayoutFile.parse(yaml: text)
                else { return nil }
                return LayoutTemplate(name: fileURL.deletingPathExtension().lastPathComponent, file: file)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func load(name: String) -> LayoutFile? {
        guard let text = try? String(contentsOf: url(forName: name), encoding: .utf8) else { return nil }
        return try? LayoutFile.parse(yaml: text)
    }

    /// Save `file` under `name`, overwriting any existing template of that name.
    /// The project-name field is cleared so the template applies to any project
    /// without a mismatch warning.
    func save(name: String, file: LayoutFile) throws {
        ensureDirectory()
        var template = file
        template.name = nil
        try template.yaml().write(to: url(forName: name), atomically: true, encoding: .utf8)
    }

    func delete(name: String) {
        try? FileManager.default.removeItem(at: url(forName: name))
    }

    // MARK: - Built-in starters

    /// Seed the built-in starters once (guarded by a UserDefaults flag) so the
    /// library isn't empty out of the box. They become plain files after
    /// seeding — deletable, and never recreated once the flag is set.
    func seedBuiltInsIfNeeded(defaults: UserDefaults = .standard) {
        let key = "macterm.layouts.builtinsSeeded"
        guard !defaults.bool(forKey: key) else { return }
        for (name, file) in Self.builtIns where !FileManager.default.fileExists(atPath: url(forName: name).path) {
            try? save(name: name, file: file)
        }
        defaults.set(true, forKey: key)
    }

    /// Structure-only starters (splits + plain shells, no commands), generic
    /// enough to seed any project.
    static var builtIns: [(name: String, file: LayoutFile)] {
        let plain = LayoutNode.pane(LayoutPane(cwd: nil, run: nil, shell: nil))
        // Two panes side by side.
        let twoPanes = LayoutFile(name: nil, tabs: [
            LayoutTab(name: nil, layout: .split(LayoutBranch(
                direction: .horizontal, ratio: 0.5, first: plain, second: plain
            ))),
        ])
        // A large main pane on the left, two stacked panes on the right.
        let mainSidebar = LayoutFile(name: nil, tabs: [
            LayoutTab(name: nil, layout: .split(LayoutBranch(
                direction: .horizontal, ratio: 0.65,
                first: plain,
                second: .split(LayoutBranch(direction: .vertical, ratio: 0.5, first: plain, second: plain))
            ))),
        ])
        return [("Two Panes", twoPanes), ("Main + Sidebar", mainSidebar)]
    }
}
