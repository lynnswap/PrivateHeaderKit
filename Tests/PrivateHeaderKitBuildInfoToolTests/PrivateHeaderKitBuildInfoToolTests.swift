import Foundation
import Testing

@testable import PrivateHeaderKitBuildInfoTool

@Suite
struct PrivateHeaderKitBuildInfoToolTests {
    @Test func environmentVersionWinsWithoutReadingGit() throws {
        let version = try BuildVersionResolver.resolve(
            environmentVersion: "  v1.2.3  ",
            packageDirectory: URL(fileURLWithPath: "/package"),
            gitDescribe: { _ in
                Issue.record("environment version must bypass Git")
                return nil
            }
        )

        #expect(version == "v1.2.3")
    }

    @Test func gitIdentityIsRequiredWhenTheEnvironmentHasNoVersion() throws {
        let version = try BuildVersionResolver.resolve(
            environmentVersion: nil,
            packageDirectory: URL(fileURLWithPath: "/package"),
            gitDescribe: { _ in "a824233-dirty\n" }
        )
        #expect(version == "a824233-dirty")

        #expect(throws: BuildInfoToolError.self) {
            _ = try BuildVersionResolver.resolve(
                environmentVersion: nil,
                packageDirectory: URL(fileURLWithPath: "/package"),
                gitDescribe: { _ in nil }
            )
        }
    }

    @Test func generatedSourceEscapesAValidSwiftStringLiteral() {
        let source = BuildVersionResolver.generatedSource(version: #"v1.2.3-"quoted"\path"#)

        #expect(source.contains(#"package static let version = "v1.2.3-\"quoted\"\\path""#))
    }

    @Test func dirtyFingerprintTracksChangedAndUntrackedSourceContents() {
        #expect(
            BuildVersionResolver.dirtyFingerprint(
                trackedDiff: Data(),
                untrackedRecords: []
            ) == nil
        )

        let firstTracked = BuildVersionResolver.dirtyFingerprint(
            trackedDiff: Data("first diff".utf8),
            untrackedRecords: []
        )
        let secondTracked = BuildVersionResolver.dirtyFingerprint(
            trackedDiff: Data("second diff".utf8),
            untrackedRecords: []
        )
        #expect(firstTracked != secondTracked)

        let firstUntracked = BuildVersionResolver.dirtyFingerprint(
            trackedDiff: Data(),
            untrackedRecords: [
                .init(
                    path: "Sources/New.swift",
                    kind: "regular",
                    contentDigest: Data("first contents".utf8)
                ),
            ]
        )
        let secondUntracked = BuildVersionResolver.dirtyFingerprint(
            trackedDiff: Data(),
            untrackedRecords: [
                .init(
                    path: "Sources/New.swift",
                    kind: "regular",
                    contentDigest: Data("second contents".utf8)
                ),
            ]
        )
        #expect(firstUntracked != secondUntracked)
    }
}
