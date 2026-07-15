import AppKit
import SwiftUI

// MARK: - Overlay

/// Overlay hosting the context picker (`cmd+shift+p`) — the name-first task
/// switcher. Same floating-panel styling as the command palette, but scoped to
/// contexts: fuzzy-match an existing one, or type a new name to create it.
struct ContextPickerOverlay: View {
    @Environment(AppState.self)
    private var appState

    private static let cornerRadius: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                // Click-outside scrim. Transparent but hit-testable.
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        appState.isContextPickerVisible = false
                    }

                ContextPickerPanel()
                    .frame(width: 500)
                    .contextPickerBackground(cornerRadius: Self.cornerRadius)
                    .overlay(
                        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                            .strokeBorder(MactermTheme.border, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 20, x: 0, y: 8)
                    .padding(.top, geo.size.height * 0.15)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private extension View {
    /// Liquid glass on macOS 26; the closest native material on older systems.
    @ViewBuilder
    func contextPickerBackground(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
        }
    }
}

// MARK: - Panel

struct ContextPickerPanel: View {
    @Environment(AppState.self)
    private var appState
    @Environment(ProjectStore.self)
    private var projectStore

    /// Two phases in one overlay. `.search` fuzzy-matches existing contexts and
    /// directories; `.pickDirectory` is the in-app folder picker reached from the
    /// "Create" row — it replaces the old Finder panel.
    private enum Mode: Equatable {
        case search
        case pickDirectory(name: String)
        case pickLayout(name: String, path: String)
    }

    @State
    private var mode: Mode = .search
    @State
    private var selectedIndex = 0
    /// Set when the last `selectedIndex` change came from mouse hover, so the
    /// keyboard-nav auto-scroll can skip it (the list shouldn't move under the
    /// cursor).
    @State
    private var selectionFromHover = false
    /// The directory-pick phase's own query, kept separate from the search
    /// phase's `appState.contextPickerQuery` so escaping back restores the name.
    @State
    private var dirQuery = ""
    /// Matching directories (zoxide ∪ fd) for the active query, fetched
    /// asynchronously off the main thread. Empty when nothing matches.
    @State
    private var dirResults: [String] = []
    /// Templates offered in the `.pickLayout` phase, snapshotted from the library
    /// when the phase is entered (so the list isn't re-read from disk per render).
    @State
    private var layoutTemplates: [LayoutTemplate] = []
    /// The layout phase's own filter query.
    @State
    private var layoutQuery = ""
    @FocusState
    private var isFieldFocused: Bool

    /// A row in the results list: an existing context, a directory match, or the
    /// "create" affordance. `fileprivate` (not `private`) so the rendering
    /// extension below can reference `ContextPickerPanel.Row`.
    fileprivate enum Row: Identifiable {
        /// `active` = the context has live tabs/panes (opened this session);
        /// inactive ones (saved state only) render dimmed.
        case project(Project, active: Bool)
        case directory(String)
        case create(String)
        case layout(LayoutChoiceRow)

        var id: String {
            switch self {
            case let .project(project, _): "project:\(project.id.uuidString)"
            case let .directory(path): "dir:\(path)"
            case let .create(name): "create:\(name)"
            case let .layout(choice): "layout:\(choice.id)"
            }
        }
    }

    /// A choice in the `.pickLayout` phase: the default single pane, or a saved
    /// template. `file` nil → default (no layout applied).
    fileprivate enum LayoutChoiceRow: Identifiable {
        case defaultLayout
        case template(LayoutTemplate)

        var id: String {
            switch self {
            case .defaultLayout: "__default__"
            case let .template(t): "tmpl:\(t.name)"
            }
        }

        var title: String {
            switch self {
            case .defaultLayout: "Default (single pane)"
            case let .template(t): t.name
            }
        }

        var file: LayoutFile? {
            switch self {
            case .defaultLayout: nil
            case let .template(t): t.file
            }
        }
    }

    /// The query the user is currently typing, depending on phase.
    private var activeQuery: String {
        switch mode {
        case .search: appState.contextPickerQuery
        case .pickDirectory: dirQuery
        case .pickLayout: layoutQuery
        }
    }

    /// Identity for the directory lookup + selection reset: changes on every
    /// keystroke and on phase switch.
    private var searchID: String {
        switch mode {
        case .search: "search:\(appState.contextPickerQuery)"
        case let .pickDirectory(name): "dir:\(name):\(dirQuery)"
        case let .pickLayout(name, _): "layout:\(name):\(layoutQuery)"
        }
    }

    private var fieldText: Binding<String> {
        switch mode {
        case .search:
            Binding(get: { appState.contextPickerQuery }, set: { appState.contextPickerQuery = $0 })
        case .pickDirectory:
            $dirQuery
        case .pickLayout:
            $layoutQuery
        }
    }

    private var placeholder: String {
        switch mode {
        case .search: "Open or create a context…"
        case let .pickDirectory(name): "Folder for “\(name)” — type to search…"
        case let .pickLayout(name, _): "Layout for “\(name)” — type to filter…"
        }
    }

    private var leadingIcon: String {
        switch mode {
        case .search: "magnifyingglass"
        case .pickDirectory: "folder.badge.plus"
        case .pickLayout: "rectangle.split.2x1"
        }
    }

    /// Directory matches for the active query: a literal existing path the user
    /// typed (escape hatch for folders outside the search root) followed by the
    /// fuzzy `zoxide ∪ fd` results, de-duplicated.
    private func directoryMatches() -> [String] {
        var dirs = dirResults
        let expanded = (activeQuery as NSString).expandingTildeInPath
        if expanded.hasPrefix("/"), isDirectory(expanded), !dirs.contains(expanded) {
            dirs.insert(expanded, at: 0)
        }
        return dirs
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private var rows: [Row] {
        switch mode {
        case .search:
            // Phase 1 lists existing contexts only — never directories — so a
            // query that merely fuzzy-matches some folder can't end up naming
            // the new context after it. A query that matches no context offers a
            // "Create" row that advances to the directory picker.
            let result = ContextSearch.search(
                query: appState.contextPickerQuery,
                projects: projectStore.projects,
                // Empty query lists ALL contexts (active first, then dormant),
                // not just the recent handful — inactive ones are dimmed below.
                recent: appState.contextsForPicker(from: projectStore.projects)
            )
            var rows = result.matches.map { Row.project($0, active: appState.isProjectLoaded($0.id)) }
            if result.showCreateRow {
                rows.append(.create(appState.contextPickerQuery.trimmingCharacters(in: .whitespaces)))
            }
            return rows
        case .pickDirectory:
            return directoryMatches().map(Row.directory)
        case .pickLayout:
            // Default single pane first, then the saved templates, filtered by
            // the typed query (Default matches an empty query and "default").
            var choices: [LayoutChoiceRow] = [.defaultLayout]
            choices += layoutTemplates.map(LayoutChoiceRow.template)
            let q = layoutQuery.trimmingCharacters(in: .whitespaces)
            let filtered = q.isEmpty ? choices : choices.filter { $0.title.localizedCaseInsensitiveContains(q) }
            return filtered.map(Row.layout)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: leadingIcon)
                    .font(.system(size: 14))
                    .foregroundStyle(MactermTheme.fgMuted)
                TextField(placeholder, text: fieldText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(MactermTheme.fg)
                    .focused($isFieldFocused)
                    .onSubmit { execute() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().background(MactermTheme.border)

            // Results
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                            Button {
                                selectedIndex = idx
                                execute()
                            } label: {
                                row.view(isSelected: idx == selectedIndex)
                            }
                            .buttonStyle(.plain)
                            .id(idx)
                            .onHover { hovering in
                                guard hovering, selectedIndex != idx else { return }
                                selectionFromHover = true
                                selectedIndex = idx
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 340)
                .onChange(of: selectedIndex) { _, idx in
                    if selectionFromHover {
                        selectionFromHover = false
                    } else {
                        proxy.scrollTo(idx)
                    }
                }
            }
        }
        .onAppear {
            selectedIndex = 0
            // Defer focus to the next runloop so the TextField has been created.
            DispatchQueue.main.async { isFieldFocused = true }
        }
        .onChange(of: searchID) {
            selectedIndex = 0
        }
        // Look up matching directories (zoxide ∪ fd) — only in the directory
        // phase; Phase 1 never matches directories. `.task(id:)` cancels the
        // in-flight lookup when the query changes, and the short sleep debounces
        // per-keystroke subprocess spawns.
        .task(id: searchID) {
            guard case .pickDirectory = mode else {
                dirResults = []
                return
            }
            let keywords = dirQuery
                .split(separator: " ")
                .map(String.init)
            guard !keywords.isEmpty else {
                dirResults = []
                return
            }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let dirs = await DirectorySearch.standard.search(keywords: keywords)
            guard !Task.isCancelled else { return }
            dirResults = dirs
        }
        .onKeyPress(keys: [.upArrow], phases: [.down, .repeat]) { _ in moveSelection(-1) }
        .onKeyPress(keys: [.downArrow], phases: [.down, .repeat]) { _ in moveSelection(1) }
        .onKeyPress(characters: .init(charactersIn: "p"), phases: [.down, .repeat]) { press in
            guard press.modifiers == .control else { return .ignored }
            return moveSelection(-1)
        }
        .onKeyPress(characters: .init(charactersIn: "n"), phases: [.down, .repeat]) { press in
            guard press.modifiers == .control else { return .ignored }
            return moveSelection(1)
        }
        .onKeyPress(keys: [.tab], phases: [.down, .repeat]) { press in
            cycleSelection(press.modifiers.contains(.shift) ? -1 : 1)
        }
        .onKeyPress(.escape) { handleEscape() }
    }

    private func moveSelection(_ delta: Int) -> KeyPress.Result {
        let next = selectedIndex + delta
        if next >= 0, next < rows.count { selectedIndex = next }
        return .handled
    }

    /// Tab cycles the selection through the matches (wrapping); Shift+Tab cycles
    /// back. Always handled so Tab never escapes the picker into the terminal's
    /// focus chain — the user commits the highlighted row with Enter.
    private func cycleSelection(_ delta: Int) -> KeyPress.Result {
        let count = rows.count
        guard count > 0 else { return .handled }
        selectedIndex = ((selectedIndex + delta) % count + count) % count
        return .handled
    }

    /// Escape backs out of the directory phase to the search phase (keeping the
    /// typed name); from the search phase it dismisses the picker.
    private func handleEscape() -> KeyPress.Result {
        switch mode {
        case .search:
            close()
        case .pickDirectory:
            mode = .search
            dirResults = []
            selectedIndex = 0
            DispatchQueue.main.async { isFieldFocused = true }
        case let .pickLayout(name, _):
            // Back up to re-pick the folder for this context.
            enterDirectoryPick(name: name)
        }
        return .handled
    }

    private func execute() {
        let rows = rows
        guard selectedIndex >= 0, selectedIndex < rows.count else { return }
        switch rows[selectedIndex] {
        case let .project(project, _):
            close()
            DispatchQueue.main.async { appState.selectProject(project) }
        case let .directory(path):
            // Search phase names the context by the folder basename; the
            // directory phase uses the task name the user already typed.
            let name = switch mode {
            case let .pickDirectory(taskName): taskName
            default: (path as NSString).lastPathComponent
            }
            // Offer a layout choice when the library has templates; otherwise
            // create straight away with the default single pane (no friction).
            let templates = LayoutLibrary.standard.list()
            if templates.isEmpty {
                close()
                DispatchQueue.main.async { appState.createContext(named: name, atPath: path, store: projectStore) }
            } else {
                enterLayoutPick(name: name, path: path, templates: templates)
            }
        case let .create(name):
            // Advance to the in-app directory picker instead of Finder.
            enterDirectoryPick(name: name)
        case let .layout(choice):
            guard case let .pickLayout(name, path) = mode else { return }
            close()
            DispatchQueue.main.async {
                appState.createContext(named: name, atPath: path, store: projectStore, layout: choice.file)
            }
        }
    }

    /// Switch to the directory-pick phase for `name`, clearing the folder query.
    private func enterDirectoryPick(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        mode = .pickDirectory(name: trimmed)
        dirQuery = ""
        dirResults = []
        selectedIndex = 0
        DispatchQueue.main.async { isFieldFocused = true }
    }

    /// Switch to the layout-pick phase, snapshotting the available templates.
    private func enterLayoutPick(name: String, path: String, templates: [LayoutTemplate]) {
        layoutTemplates = templates
        layoutQuery = ""
        mode = .pickLayout(name: name, path: path)
        selectedIndex = 0
        DispatchQueue.main.async { isFieldFocused = true }
    }

    private func close() {
        appState.isContextPickerVisible = false
        appState.contextPickerQuery = ""
    }
}

// MARK: - Row

private extension ContextPickerPanel.Row {
    @ViewBuilder
    func view(isSelected: Bool) -> some View {
        switch self {
        case let .project(project, active):
            ContextPickerRow(
                systemImage: "folder",
                title: project.name,
                subtitle: project.path,
                isSelected: isSelected,
                isActive: active
            )
        case let .directory(path):
            ContextPickerRow(
                systemImage: "folder.badge.plus",
                title: (path as NSString).lastPathComponent,
                subtitle: path,
                isSelected: isSelected
            )
        case let .create(name):
            ContextPickerRow(
                systemImage: "plus.circle",
                title: "Create context “\(name)”",
                subtitle: "Pick a folder…",
                isSelected: isSelected
            )
        case let .layout(choice):
            ContextPickerRow(
                systemImage: choice.file == nil ? "rectangle" : "rectangle.split.2x1",
                title: choice.title,
                subtitle: choice.file == nil ? "One pane at the project root" : "Saved layout",
                isSelected: isSelected
            )
        }
    }
}

private struct ContextPickerRow: View {
    let systemImage: String
    let title: String
    let subtitle: String?
    let isSelected: Bool
    /// Inactive contexts (saved state, no live tabs/panes) render dimmed so
    /// they're distinguishable from the ones you're currently working in but
    /// still selectable. Non-context rows (create/directory/layout) pass true.
    var isActive = true

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .foregroundStyle(MactermTheme.fgMuted)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(MactermTheme.fg)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(MactermTheme.fgMuted)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        // Dim the content (not the selection highlight) for inactive contexts.
        .opacity(isActive ? 1 : 0.55)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isSelected ? MactermTheme.fg.opacity(0.12) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 6)
    }
}
