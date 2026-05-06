// Copyright (C) 2026 Connor Needling
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import Foundation

/// Codable model for the GitHub Releases API
/// https://docs.github.com/en/rest/releases/releases#get-the-latest-release
struct GitHubRelease: Codable, Sendable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL
    let publishedAt: Date?
    let prerelease: Bool
    let draft: Bool
    let assets: [Asset]

    struct Asset: Codable, Sendable {
        let name: String
        let browserDownloadURL: URL
        let size: Int
        let contentType: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
            case contentType = "content_type"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case prerelease
        case draft
        case assets
    }

    /// Tag name with leading "v" stripped, suitable for semver compare.
    var versionString: String {
        tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }

    /// First .zip asset attached to the release (we ship the .app inside one).
    var zipAsset: Asset? {
        assets.first { $0.name.lowercased().hasSuffix(".zip") }
    }

    /// Optional SHA-256 hex string parsed from the release body.
    /// Format expected on its own line: `SHA256: <64-hex-chars>`.
    var expectedSHA256: String? {
        guard let body else { return nil }
        for line in body.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("sha256:") else { continue }
            let hex = trimmed
                .dropFirst("sha256:".count)
                .trimmingCharacters(in: .whitespaces)
            if hex.count == 64, hex.allSatisfy(\.isHexDigit) {
                return hex.lowercased()
            }
        }
        return nil
    }
}

/// Returns true if version `a` is strictly less than version `b`.
/// Tolerant of trailing labels (e.g. "1.2.0-beta" treated as 1.2.0).
func semverLessThan(_ a: String, _ b: String) -> Bool {
    func parts(_ s: String) -> [Int] {
        s.split(separator: ".").map { component in
            let digits = component.prefix { $0.isNumber }
            return Int(digits) ?? 0
        }
    }
    let aParts = parts(a)
    let bParts = parts(b)
    let len = max(aParts.count, bParts.count)
    for i in 0..<len {
        let x = i < aParts.count ? aParts[i] : 0
        let y = i < bParts.count ? bParts[i] : 0
        if x != y { return x < y }
    }
    return false
}
