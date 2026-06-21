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
}
