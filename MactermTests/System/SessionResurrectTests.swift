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
    func boot_time_is_readable_and_positive() {
        // Sanity: kern.boottime resolves to a plausible epoch second.
        let boot = SystemBootTime.current()
        #expect(boot != nil)
        #expect((boot ?? 0) > 1_000_000_000) // after 2001
    }
}
