import Foundation
@testable import Macterm
import Testing

struct ZoxideServiceTests {
    // MARK: - Binary resolution

    @Test
    func resolves_first_executable_candidate() {
        let service = ZoxideService(
            binaryCandidates: ["/opt/homebrew/bin/zoxide", "/usr/local/bin/zoxide"],
            isExecutable: { $0 == "/usr/local/bin/zoxide" }
        )
        #expect(service.resolveBinary() == "/usr/local/bin/zoxide")
    }

    @Test
    func prefers_higher_priority_candidate() {
        let service = ZoxideService(
            binaryCandidates: ["/a/zoxide", "/b/zoxide"],
            isExecutable: { $0 == "/a/zoxide" || $0 == "/b/zoxide" }
        )
        #expect(service.resolveBinary() == "/a/zoxide")
    }

    @Test
    func nil_when_no_candidate_is_executable() {
        let service = ZoxideService(binaryCandidates: ["/a/zoxide"], isExecutable: { _ in false })
        #expect(service.resolveBinary() == nil)
    }

    // MARK: - Output parsing

    @Test
    func parses_one_path_per_line_keeping_only_existing_dirs() {
        let output = """
        /Users/me/code/terraform-mh-serverless
        /Users/me/code/gone
        /Users/me/code/terraform-mh-serverless-module
        """
        let existing: Set = [
            "/Users/me/code/terraform-mh-serverless",
            "/Users/me/code/terraform-mh-serverless-module",
        ]
        let dirs = ZoxideService.parse(output: output, limit: 8) { existing.contains($0) }
        #expect(dirs == [
            "/Users/me/code/terraform-mh-serverless",
            "/Users/me/code/terraform-mh-serverless-module",
        ])
    }

    @Test
    func parse_trims_blank_lines_and_whitespace() {
        let output = "  /Users/me/a  \n\n/Users/me/b\n"
        let dirs = ZoxideService.parse(output: output, limit: 8) { _ in true }
        #expect(dirs == ["/Users/me/a", "/Users/me/b"])
    }

    @Test
    func parse_caps_at_limit() {
        let output = (1 ... 20).map { "/dir/\($0)" }.joined(separator: "\n")
        let dirs = ZoxideService.parse(output: output, limit: 5) { _ in true }
        #expect(dirs.count == 5)
    }

    @Test
    func parse_empty_output_is_empty() {
        #expect(ZoxideService.parse(output: "", limit: 8) { _ in true }.isEmpty)
    }
}
