import Foundation
@testable import Macterm
import Testing

struct LayoutLibraryTests {
    /// A library rooted at a throwaway tempdir, so tests never touch real
    /// Application Support.
    private func tempLibrary() -> LayoutLibrary {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("layoutlib-\(UUID().uuidString)", isDirectory: true)
        return LayoutLibrary(directory: dir)
    }

    private func plainLayout() -> LayoutFile {
        LayoutFile(name: nil, tabs: [LayoutTab(name: nil, layout: .pane(LayoutPane(cwd: nil, run: nil, shell: nil)))])
    }

    @Test
    func save_then_load_and_list_round_trips() throws {
        let lib = tempLibrary()
        let file = LayoutFile(name: "ignored-project-name", tabs: [
            LayoutTab(name: "main", layout: .split(LayoutBranch(
                direction: .horizontal, ratio: 0.5,
                first: .pane(LayoutPane(cwd: nil, run: "nvim", shell: nil)),
                second: .pane(LayoutPane(cwd: nil, run: nil, shell: nil))
            ))),
        ])
        try lib.save(name: "My Layout", file: file)

        let loaded = lib.load(name: "My Layout")
        #expect(loaded != nil)
        #expect(loaded?.name == nil) // project name cleared — templates aren't project-specific
        #expect(loaded?.tabs.count == 1)
        #expect(lib.list().map(\.name) == ["My Layout"])
    }

    @Test
    func sanitized_name_replaces_path_separators_and_trims() {
        #expect(LayoutLibrary.sanitized("a/b:c") == "a-b-c")
        #expect(LayoutLibrary.sanitized("  spaced  ") == "spaced")
    }

    @Test
    func delete_removes_the_template() throws {
        let lib = tempLibrary()
        try lib.save(name: "Temp", file: plainLayout())
        #expect(lib.load(name: "Temp") != nil)
        lib.delete(name: "Temp")
        #expect(lib.load(name: "Temp") == nil)
        #expect(lib.list().isEmpty)
    }

    @Test
    func list_skips_unparseable_and_non_yaml_files() throws {
        let lib = tempLibrary()
        try lib.save(name: "Good", file: plainLayout())
        try "not: [valid".write(to: lib.directory.appendingPathComponent("Bad.yaml"), atomically: true, encoding: .utf8)
        try "ignore me".write(to: lib.directory.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        #expect(lib.list().map(\.name) == ["Good"])
    }

    @Test
    func built_ins_round_trip_through_yaml() throws {
        for (_, file) in LayoutLibrary.builtIns {
            let parsed = try LayoutFile.parse(yaml: file.yaml())
            #expect(parsed.tabs.count == 1)
        }
    }

    @Test
    func seed_built_ins_writes_once_then_respects_deletion() throws {
        let lib = tempLibrary()
        let defaults = try #require(UserDefaults(suiteName: "seed-\(UUID().uuidString)"))
        lib.seedBuiltInsIfNeeded(defaults: defaults)
        #expect(Set(lib.list().map(\.name)) == Set(LayoutLibrary.builtIns.map(\.name)))

        // Re-seeding after deleting one must NOT recreate it (the flag is set).
        let first = LayoutLibrary.builtIns[0].name
        lib.delete(name: first)
        lib.seedBuiltInsIfNeeded(defaults: defaults)
        #expect(!lib.list().contains { $0.name == first })
    }
}
