// Standalone test runner (no XCTest target in project).
// Run: swiftc -parse-as-library UltimateYTM/Utilities/DockPillEstimator.swift Tests/DockPillEstimatorTests.swift -o /tmp/dpe-test && /tmp/dpe-test

import CoreGraphics
import Foundation

@main
struct DockPillEstimatorTests {
    static func main() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
        }

        // Ground truth measured on macOS 27 beta 4 (build 26A5388g):
        // tilesize 56, 23 icon items, 2 separators -> AXList width 1450.
        expect(DockPillEstimator.pillWidth(tilesize: 56, itemCount: 23, separatorCount: 2) == 1450,
               "beta4 ground-truth width")
        expect(DockPillEstimator.pillWidth(tilesize: 0, itemCount: 23, separatorCount: 2) == 0,
               "zero tilesize -> 0")
        expect(DockPillEstimator.pillWidth(tilesize: 56, itemCount: 0, separatorCount: 0) == 0,
               "zero items -> 0")

        // Measured layout: 15 pinned apps (Finder not pinned), 5 folders, 1 running unpinned
        // app, recents shown but empty -> 16 apps + 1 middle + 6 others = 23 items, 2 separators.
        let pinned = (1...15).map { "com.pinned.app\($0)" }
        let c1 = DockPillEstimator.counts(
            persistentAppIDs: pinned,
            otherItemCount: 5,
            recentAppIDs: [],
            runningAppIDs: pinned + ["com.apple.finder", "com.example.unpinned"])
        expect(c1.items == 23 && c1.separators == 2, "measured beta4 dock layout")

        // Minimal dock: 1 pinned app, nothing else running but Finder, no folders.
        // -> pinned + Finder + Trash = 3 items, only the trailing separator.
        let c2 = DockPillEstimator.counts(
            persistentAppIDs: ["com.pinned.app1"],
            otherItemCount: 0,
            recentAppIDs: [],
            runningAppIDs: ["com.pinned.app1", "com.apple.finder"])
        expect(c2.items == 3 && c2.separators == 1, "minimal dock, no middle section")

        // Recents and running-unpinned dedupe into one middle section.
        let c3 = DockPillEstimator.counts(
            persistentAppIDs: ["com.pinned.app1"],
            otherItemCount: 2,
            recentAppIDs: ["com.example.recent", "com.example.both"],
            runningAppIDs: ["com.apple.finder", "com.example.both"])
        expect(c3.items == 2 + 2 + 3 && c3.separators == 2, "recents/running dedupe")

        // Finder pinned explicitly must not double-count.
        let c4 = DockPillEstimator.counts(
            persistentAppIDs: ["com.apple.finder", "com.pinned.app1"],
            otherItemCount: 0,
            recentAppIDs: [],
            runningAppIDs: ["com.apple.finder"])
        expect(c4.items == 3 && c4.separators == 1, "finder pinned not double-counted")

        if failures > 0 { print("\(failures) FAILURES"); exit(1) }
        print("ALL PASS")
    }
}
