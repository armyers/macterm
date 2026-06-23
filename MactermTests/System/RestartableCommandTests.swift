import Foundation
@testable import Macterm
import Testing

struct RestartableCommandTests {
    @Test
    func returns_command_for_allowlisted_program() {
        #expect(RestartableCommand.restartable("nvim foo.txt") == "nvim foo.txt")
        #expect(RestartableCommand.restartable("vim") == "vim")
        #expect(RestartableCommand.restartable("htop") == "htop")
    }

    @Test
    func matches_on_basename_of_absolute_path() {
        #expect(RestartableCommand.restartable("/opt/homebrew/bin/hx src/main.rs") == "/opt/homebrew/bin/hx src/main.rs")
    }

    @Test
    func is_case_insensitive_on_program_name() {
        #expect(RestartableCommand.restartable("VIM notes") == "VIM notes")
    }

    @Test
    func rejects_non_allowlisted_programs() {
        #expect(RestartableCommand.restartable("npm run dev") == nil)
        #expect(RestartableCommand.restartable("python server.py") == nil)
        #expect(RestartableCommand.restartable("ssh host") == nil)
    }

    @Test
    func nil_for_nil_or_empty_input() {
        #expect(RestartableCommand.restartable(nil) == nil)
        #expect(RestartableCommand.restartable("") == nil)
    }
}
