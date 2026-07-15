import Foundation
@testable import Macterm
import Testing

struct ScrollbackEditorTests {
    @Test
    func command_prefers_visual_then_editor_then_vi_and_opens_at_line() {
        let cmd = ScrollbackEditor.command(forPath: "/tmp/cyote-arm-scrollback-abc.txt", openAtLine: 500)
        #expect(cmd == "exec ${VISUAL:-${EDITOR:-vi}} +500 '/tmp/cyote-arm-scrollback-abc.txt'")
    }

    @Test
    func command_clamps_line_to_at_least_one() {
        let cmd = ScrollbackEditor.command(forPath: "/tmp/x.txt", openAtLine: 0)
        #expect(cmd == "exec ${VISUAL:-${EDITOR:-vi}} +1 '/tmp/x.txt'")
    }

    @Test
    func command_escapes_single_quotes_in_path() {
        let cmd = ScrollbackEditor.command(forPath: "/tmp/it's a dir/log.txt", openAtLine: 3)
        // Single quote is closed, escaped, and reopened so the shell keeps the
        // literal path intact.
        #expect(cmd == "exec ${VISUAL:-${EDITOR:-vi}} +3 '/tmp/it'\\''s a dir/log.txt'")
    }
}
