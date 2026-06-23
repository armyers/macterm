import Foundation
@testable import Macterm
import Testing

struct ZmxServiceTests {
    // MARK: - Binary resolution

    @Test
    func resolves_first_executable_candidate() {
        let zmx = ZmxService(
            binaryCandidates: ["/opt/homebrew/bin/zmx", "/usr/local/bin/zmx"],
            isExecutable: { $0 == "/usr/local/bin/zmx" }
        )
        #expect(zmx.resolveBinary() == "/usr/local/bin/zmx")
        #expect(zmx.isAvailable)
    }

    @Test
    func prefers_higher_priority_candidate() {
        let zmx = ZmxService(
            binaryCandidates: ["/a/zmx", "/b/zmx"],
            isExecutable: { $0 == "/a/zmx" || $0 == "/b/zmx" }
        )
        #expect(zmx.resolveBinary() == "/a/zmx")
    }

    @Test
    func unavailable_when_no_candidate_is_executable() {
        let zmx = ZmxService(binaryCandidates: ["/a/zmx"], isExecutable: { _ in false })
        #expect(zmx.resolveBinary() == nil)
        #expect(!zmx.isAvailable)
    }

    // MARK: - Attach command

    @Test
    func attach_command_is_absolute_binary_attach_session() {
        let zmx = ZmxService(binaryCandidates: ["/opt/homebrew/bin/zmx"], isExecutable: { _ in true })
        #expect(zmx.attachCommand(sessionID: "sess-1") == "/opt/homebrew/bin/zmx attach sess-1")
    }

    @Test
    func attach_command_nil_when_unavailable() {
        let zmx = ZmxService(binaryCandidates: ["/a/zmx"], isExecutable: { _ in false })
        #expect(zmx.attachCommand(sessionID: "sess-1") == nil)
    }

    // MARK: - Launch resolution

    @Test
    func launch_zmx_runs_attach_command_with_no_shell_or_seed() {
        let launch = PaneLaunch.resolve(
            attachCommand: "/opt/homebrew/bin/zmx attach s",
            command: "nvim .",
            shell: "/bin/fish"
        )
        #expect(launch.program == "/opt/homebrew/bin/zmx attach s")
        #expect(launch.shell == nil)
        // The live session carries process state; the recorded command is not
        // replayed into it.
        #expect(launch.initialInput == nil)
    }

    @Test
    func launch_native_passes_through_shell_and_command() {
        let launch = PaneLaunch.resolve(attachCommand: nil, command: "npm run dev", shell: "/bin/fish")
        #expect(launch.program == nil)
        #expect(launch.shell == "/bin/fish")
        #expect(launch.initialInput == "npm run dev")
    }

    @Test
    func launch_native_plain_shell_has_no_program_or_seed() {
        let launch = PaneLaunch.resolve(attachCommand: nil, command: nil, shell: nil)
        #expect(launch.program == nil)
        #expect(launch.shell == nil)
        #expect(launch.initialInput == nil)
    }

    // MARK: - list parsing

    @Test
    func parses_healthy_session_line() {
        let out = "  name=ABC-123\tpid=35444\tclients=0\tcreated=1782072493\tstart_dir=/Users/me/.config\n"
        let sessions = ZmxService.parseList(out)
        #expect(sessions.count == 1)
        let s = sessions[0]
        #expect(s.name == "ABC-123")
        #expect(s.pid == 35444)
        #expect(s.clients == 0)
        #expect(s.startDir == "/Users/me/.config")
        #expect(s.isHealthy)
    }

    @Test
    func captures_start_dir_with_spaces_to_end_of_line() {
        let out = "name=X\tpid=10\tclients=1\tstart_dir=/Users/me/My Code/proj\n"
        let s = ZmxService.parseList(out)[0]
        #expect(s.startDir == "/Users/me/My Code/proj")
        #expect(s.pid == 10)
    }

    @Test
    func dead_session_is_unhealthy_with_no_pid() {
        let out = "name=DEAD-1\terr=connection refused\tstatus=unreachable\n"
        let s = ZmxService.parseList(out)[0]
        #expect(s.name == "DEAD-1")
        #expect(s.pid == nil)
        #expect(!s.isHealthy)
    }

    @Test
    func parses_multiple_lines_and_skips_blanks() {
        let out = """
          name=A\tpid=1\tclients=0\tstart_dir=/a

          name=B\tpid=2\tclients=0\tstart_dir=/b
        """
        let sessions = ZmxService.parseList(out)
        #expect(sessions.map(\.name) == ["A", "B"])
    }

    @Test
    func ignores_lines_without_name() {
        #expect(ZmxService.parseList("no sessions\n").isEmpty)
    }

    @Test
    func chunk_on_lines_splits_under_limit_at_line_boundaries() {
        // 20 lines of 100 bytes each (~2020 B) capped at 600 B → multiple chunks.
        let text = (0 ..< 20).map { _ in String(repeating: "x", count: 99) }.joined(separator: "\n") + "\n"
        let chunks = ZmxService.chunkOnLines(text, maxBytes: 600)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.utf8.count <= 600 || !$0.contains("\n") }) // only an oversize single line may exceed
        #expect(chunks.joined() == text) // lossless
        #expect(chunks.allSatisfy { $0.hasSuffix("\n") }) // broken only at line ends
    }

    @Test
    func chunk_on_lines_keeps_small_text_in_one_chunk() {
        let text = "a\nb\nc\n"
        #expect(ZmxService.chunkOnLines(text, maxBytes: 3000) == [text])
    }

    @Test
    func trailing_cmd_field_does_not_pollute_start_dir() {
        // Sessions started with a command carry a trailing `cmd=…` after
        // `start_dir=…`; splitting on TAB keeps start_dir clean.
        let out = "name=X\tpid=5\tclients=1\tstart_dir=/tmp\tcmd=top\n"
        let s = ZmxService.parseList(out)[0]
        #expect(s.startDir == "/tmp")
        #expect(s.pid == 5)
        #expect(s.isHealthy)
    }
}
