import Foundation
@testable import Macterm
import Testing

struct DirectorySearchTests {
    @Test
    func merge_keeps_zoxide_first_then_filesystem_extras() {
        let merged = DirectorySearch.merge(
            zoxide: ["/a", "/b"],
            filesystem: ["/b", "/c", "/d"],
            limit: 10
        )
        // zoxide order preserved; filesystem contributes only the new ones.
        #expect(merged == ["/a", "/b", "/c", "/d"])
    }

    @Test
    func merge_deduplicates_filesystem_against_zoxide() {
        let merged = DirectorySearch.merge(
            zoxide: ["/x"],
            filesystem: ["/x", "/x", "/y"],
            limit: 10
        )
        #expect(merged == ["/x", "/y"])
    }

    @Test
    func merge_caps_at_limit_favoring_zoxide() {
        let merged = DirectorySearch.merge(
            zoxide: ["/a", "/b", "/c"],
            filesystem: ["/d", "/e"],
            limit: 4
        )
        #expect(merged == ["/a", "/b", "/c", "/d"])
    }

    @Test
    func merge_empty_zoxide_returns_filesystem() {
        let merged = DirectorySearch.merge(zoxide: [], filesystem: ["/a", "/b"], limit: 10)
        #expect(merged == ["/a", "/b"])
    }

    @Test
    func resolves_first_executable_fd_candidate() {
        let search = DirectorySearch(
            zoxide: .standard,
            fdCandidates: ["/opt/homebrew/bin/fd", "/usr/local/bin/fd"],
            isExecutable: { $0 == "/usr/local/bin/fd" },
            searchRoot: "/tmp",
            maxDepth: 6
        )
        #expect(search.resolveFd() == "/usr/local/bin/fd")
    }

    @Test
    func nil_fd_when_no_candidate_is_executable() {
        let search = DirectorySearch(
            zoxide: .standard,
            fdCandidates: ["/a/fd"],
            isExecutable: { _ in false },
            searchRoot: "/tmp",
            maxDepth: 6
        )
        #expect(search.resolveFd() == nil)
    }
}
