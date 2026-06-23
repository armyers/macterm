import Foundation
@testable import Macterm
import Testing

@MainActor
struct SessionResurrectTests {
    @Test
    func short_scrollback_passes_through_unchanged() {
        let vt = "line one\nline two\n"
        #expect(SessionResurrect.cappedForReplay(vt) == vt)
    }

    @Test
    func long_scrollback_is_capped_to_the_tail() {
        // 4000 single-char lines (~8KB) capped to 1KB keeps only the tail.
        let vt = (0 ..< 4000).map { "L\($0 % 10)" }.joined(separator: "\n")
        let capped = SessionResurrect.cappedForReplay(vt, maxBytes: 1024)
        #expect(capped.utf8.count <= 1024)
        #expect(vt.hasSuffix(capped)) // tail preserved
        #expect(!capped.hasPrefix("\n")) // partial first line dropped, clean start
    }

    @Test
    func long_crlf_scrollback_is_not_collapsed_to_empty() {
        // Replay text is CRLF-normalized, and Swift treats "\r\n" as one grapheme,
        // so a Character-based `split(separator: "\n")` saw the whole dump as one
        // oversize "line" and the budget walk returned empty. Real-world repro:
        // ~576KB of color scrollback came back as 0 bytes. Must keep a real tail.
        let vt = (0 ..< 4000).map { "L\($0 % 10)" }.joined(separator: "\r\n") + "\r\n"
        let capped = SessionResurrect.cappedForReplay(vt, maxBytes: 1024)
        #expect(!capped.isEmpty)
        #expect(capped.utf8.count <= 1024)
        #expect(vt.hasSuffix(capped)) // tail preserved
    }

    @Test
    func sanitize_keeps_color_and_text_but_strips_positioning() {
        let esc = "\u{1B}"
        let vt = "\(esc)[2J\(esc)[H\(esc)[31mred\(esc)[0m\(esc)[2;8Htext\r\nmore\r"
        let clean = SessionResurrect.sanitizeForReplay(vt)
        #expect(clean.contains("\(esc)[31m")) // SGR color kept
        #expect(clean.contains("\(esc)[0m"))
        #expect(clean.contains("red") && clean.contains("text") && clean.contains("more"))
        #expect(!clean.contains("\(esc)[2J")) // clear-screen stripped
        #expect(!clean.contains("\(esc)[H")) // cursor-home stripped
        #expect(!clean.contains("\(esc)[2;8H")) // absolute position stripped
        #expect(clean.contains("text\r\nmore")) // line breaks emitted as CRLF
        #expect(clean.hasSuffix("\r\n")) // trailing lone CR normalized to CRLF
    }

    @Test
    func sanitize_strips_osc_and_private_modes() {
        let esc = "\u{1B}"
        let vt = "\(esc)[?2004h\(esc)]0;window title\u{07}hello\(esc)[?12h"
        #expect(SessionResurrect.sanitizeForReplay(vt) == "hello")
    }

    @Test
    func trims_trailing_blank_lines_but_keeps_interior() {
        let input = "line one\n\nline two\n   \n\t\n\n"
        let out = SessionResurrect.trimTrailingBlankLines(input)
        // Interior blank kept, trailing blank lines dropped; the last real line
        // keeps its own newline (line terminators are preserved, not re-joined).
        #expect(out == "line one\n\nline two\n")
    }

    @Test
    func boot_time_is_readable_and_positive() {
        // Sanity: kern.boottime resolves to a plausible epoch second.
        let boot = SystemBootTime.current()
        #expect(boot != nil)
        #expect((boot ?? 0) > 1_000_000_000) // after 2001
    }
}
