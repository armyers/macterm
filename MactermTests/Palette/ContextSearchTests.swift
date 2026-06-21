import Foundation
@testable import Macterm
import Testing

struct ContextSearchTests {
    private func project(_ name: String, _ path: String = "/tmp") -> Project {
        Project(name: name, path: path, sortOrder: 0)
    }

    // MARK: - Empty query

    @Test
    func empty_query_returns_recents_and_no_create_row() {
        let recent = [project("alpha"), project("beta")]
        let result = ContextSearch.search(
            query: "",
            projects: [project("alpha"), project("beta"), project("gamma")],
            recent: recent
        )
        #expect(result.matches.map(\.name) == ["alpha", "beta"])
        #expect(result.showCreateRow == false)
    }

    @Test
    func whitespace_only_query_is_treated_as_empty() {
        let result = ContextSearch.search(
            query: "   ",
            projects: [project("alpha")],
            recent: [project("alpha")]
        )
        #expect(result.showCreateRow == false)
    }

    // MARK: - Fuzzy ranking

    @Test
    func ranks_prefix_match_above_subsequence_match() {
        let result = ContextSearch.search(
            query: "fix",
            projects: [project("refactor-fixtures"), project("fix login bug")],
            recent: []
        )
        // "fix login bug" is a prefix match (score 0); the other only matches as
        // a substring/subsequence, so the prefix match ranks first.
        #expect(result.matches.first?.name == "fix login bug")
    }

    @Test
    func matches_on_path_when_name_does_not() {
        let result = ContextSearch.search(
            query: "deploy",
            projects: [project("TF stacks", "/Users/me/deploy-infra")],
            recent: []
        )
        #expect(result.matches.map(\.name) == ["TF stacks"])
    }

    @Test
    func non_matching_query_returns_no_matches_but_offers_create() {
        let result = ContextSearch.search(
            query: "zzzzz",
            projects: [project("alpha")],
            recent: []
        )
        #expect(result.matches.isEmpty)
        #expect(result.showCreateRow == true)
    }

    // MARK: - Create row

    @Test
    func novel_name_offers_create_row() {
        let result = ContextSearch.search(
            query: "review PR 98",
            projects: [project("alpha")],
            recent: []
        )
        #expect(result.showCreateRow == true)
    }

    @Test
    func exact_name_match_suppresses_create_row() {
        let result = ContextSearch.search(
            query: "alpha",
            projects: [project("alpha")],
            recent: []
        )
        #expect(result.showCreateRow == false)
    }

    @Test
    func exact_name_match_is_case_insensitive() {
        let result = ContextSearch.search(
            query: "ALPHA",
            projects: [project("alpha")],
            recent: []
        )
        #expect(result.showCreateRow == false)
    }
}
