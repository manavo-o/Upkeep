import XCTest
@testable import UpkeepCore

final class UpkeepTests: XCTestCase {
    func testStripANSI() {
        let raw = "\u{001B}[32m✓ User app cache · 18 items, 2.4GB\u{001B}[0m"
        let clean = CLIExecutor.stripANSI(raw)
        XCTAssertEqual(clean, "✓ User app cache · 18 items, 2.4GB")
    }

    func testParseMoleOutput() {
        let sample = """
        ➤ User essentials
        ✓ User app cache · 18 items, 2.4GB
        ✓ User app logs · 7 items, 12.8MB
        Removed: 4.5GB · 97 items
        """
        let summary = MoleService.parseCleanOutput(sample, isDryRun: false)
        XCTAssertEqual(summary.totalReclaimed, "4.5GB")
        XCTAssertEqual(summary.itemCount, 2)
        XCTAssertEqual(summary.lines.count, 3)
    }

    func testFuzzyRanking() {
        let exact = SwiftFuzzyMatcher.score(query: "ripgrep", candidate: "ripgrep") ?? -1
        let prefix = SwiftFuzzyMatcher.score(query: "rip", candidate: "ripgrep") ?? -1
        let loose = SwiftFuzzyMatcher.score(query: "rip", candidate: "archive-zip") ?? -1
        XCTAssertGreaterThan(exact, prefix)
        XCTAssertGreaterThan(prefix, loose)
    }

    @MainActor
    func testKeepAwakeLifecycle() {
        let manager = KeepAwakeManager.shared
        manager.start(durationMinutes: 30, mode: .displayAndSystem)
        XCTAssertTrue(manager.isActive)
        XCTAssertNotNil(manager.remainingSeconds)
        manager.stop()
        XCTAssertFalse(manager.isActive)
        XCTAssertEqual(manager.formattedRemaining, "Off")
    }
}
