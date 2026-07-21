// Standalone test runner (no XCTest target in project).
// Run: swiftc -parse-as-library UltimateYTM/Models/GitHubRelease.swift Tests/GitHubReleaseTests.swift -o /tmp/ghr-test && /tmp/ghr-test

import Foundation

@main
struct GitHubReleaseTests {
    static func makeRelease(body: String?) -> GitHubRelease {
        let json = """
        {
            "tag_name": "v1.1.3",
            "name": "test",
            "body": \(body.map { "\"\($0.replacingOccurrences(of: "\n", with: "\\n"))\"" } ?? "null"),
            "html_url": "https://example.com",
            "published_at": null,
            "prerelease": false,
            "draft": false,
            "assets": []
        }
        """
        return try! JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
    }

    static func main() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
        }

        let r1 = makeRelease(body: "# Notes\nmin-os: 27.0\nmore text")
        expect(r1.minimumOSVersion?.majorVersion == 27 && r1.minimumOSVersion?.minorVersion == 0,
               "parses min-os: 27.0")

        let r2 = makeRelease(body: "Min-OS: 28.1.2")
        expect(r2.minimumOSVersion?.majorVersion == 28
               && r2.minimumOSVersion?.minorVersion == 1
               && r2.minimumOSVersion?.patchVersion == 2,
               "case-insensitive, three components")

        let r3 = makeRelease(body: "no marker here\nsha256: abc")
        expect(r3.minimumOSVersion == nil, "absent marker -> nil")

        let r4 = makeRelease(body: nil)
        expect(r4.minimumOSVersion == nil, "nil body -> nil")

        let r5 = makeRelease(body: "min-os: banana")
        expect(r5.minimumOSVersion == nil, "garbage value -> nil")

        let r6 = makeRelease(body: "  min-os:   27.0  ")
        expect(r6.minimumOSVersion?.majorVersion == 27, "tolerates whitespace")

        // Running OS is macOS 27.x here, so a 27.0 floor passes and a 99.0 floor fails.
        expect(ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)),
               "sanity: host satisfies 27.0")
        expect(!ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 99, minorVersion: 0, patchVersion: 0)),
               "sanity: host fails 99.0")

        if failures > 0 { print("\(failures) FAILURES"); exit(1) }
        print("ALL PASS")
    }
}
