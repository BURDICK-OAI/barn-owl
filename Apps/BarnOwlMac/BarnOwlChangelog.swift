import Foundation

struct BarnOwlChangelogRelease: Codable, Equatable, Identifiable {
    var version: String
    var build: String
    var date: String
    var title: String
    var highlights: [String]

    var id: String {
        "\(version)-\(build)"
    }

    var versionLabel: String {
        "\(version) (\(build))"
    }
}

enum BarnOwlChangelog {
    static let resourceName = "BarnOwlChangelog"
    static let resourceExtension = "json"

    static var releases: [BarnOwlChangelogRelease] {
        loadReleases()
    }

    static var latestRelease: BarnOwlChangelogRelease? {
        releases.first
    }

    static func release(version: String, build: String) -> BarnOwlChangelogRelease? {
        releases.first {
            $0.version == version && $0.build == build
        }
    }

    static func updateManifestNotes(version: String, build: String) -> String? {
        guard let release = release(version: version, build: build) else {
            return nil
        }

        let summary = release.highlights
            .prefix(3)
            .joined(separator: " ")
        return summary.isEmpty ? release.title : summary
    }

    private static func loadReleases(bundle: Bundle = .main) -> [BarnOwlChangelogRelease] {
        guard let url = bundle.url(forResource: resourceName, withExtension: resourceExtension),
              let data = try? Data(contentsOf: url),
              let releases = try? JSONDecoder().decode([BarnOwlChangelogRelease].self, from: data)
        else {
            return []
        }

        return releases
    }
}
