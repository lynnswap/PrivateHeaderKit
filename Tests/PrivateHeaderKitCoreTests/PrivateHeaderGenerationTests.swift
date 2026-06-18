import Foundation
import Testing

import PrivateHeaderKitCore

@Suite
struct PrivateHeaderGenerationLabelTests {
    @Test func iOSSourceLabelUsesUserFacingDisplayAndCompactDirectoryNames() {
        let source = PrivateHeaderGeneration.Source(
            platform: .iOS,
            version: "27.0",
            build: "24A5355q"
        )

        #expect(source.label.displayName == "iOS 27.0 (24A5355q)")
        #expect(source.label.directoryName == "iOS27.0(24A5355q)")
        #expect(source.label.description == "iOS 27.0 (24A5355q)")
    }

    @Test func macOSSourceLabelUsesUserFacingDisplayAndCompactDirectoryNames() {
        let source = PrivateHeaderGeneration.Source(
            platform: .macOS,
            version: "16.0",
            build: "25A5279m"
        )

        #expect(source.label.displayName == "macOS 16.0 (25A5279m)")
        #expect(source.label.directoryName == "macOS16.0(25A5279m)")
    }

    @Test func sourceLabelOmitsEmptyBuild() {
        let source = PrivateHeaderGeneration.Source(
            platform: .iOS,
            version: "27.0",
            build: ""
        )

        #expect(source.label.displayName == "iOS 27.0")
        #expect(source.label.directoryName == "iOS27.0")
    }
}

@Suite
struct PrivateHeaderGenerationPlanTests {
    @Test func planKeepsStateOutsideArtifactDirectoryAndUsesSourceLabelAsResumeKey() {
        let source = PrivateHeaderGeneration.Source(
            platform: .iOS,
            version: "27.0",
            build: "24A5355q"
        )
        let root = URL(fileURLWithPath: "/tmp/PrivateHeaderKit", isDirectory: true)

        let plan = PrivateHeaderGeneration.makePlan(
            source: source,
            artifactRootDirectory: root
        )

        #expect(plan.source == source)
        #expect(plan.artifactRootDirectory == root)
        #expect(plan.artifactDirectory.path == "/tmp/PrivateHeaderKit/iOS27.0(24A5355q)")
        #expect(plan.stateDirectory.path == "/tmp/PrivateHeaderKit/.state/iOS27.0(24A5355q)")
        #expect(plan.target == .allAvailable)
    }

    @Test func generatePrivateHeadersThrowsExplicitUnimplementedError() async throws {
        let source = PrivateHeaderGeneration.Source(
            platform: .macOS,
            version: "16.0",
            build: "25A5279m"
        )
        let root = URL(fileURLWithPath: "/tmp/PrivateHeaderKit", isDirectory: true)

        do {
            _ = try await PrivateHeaderGeneration.generatePrivateHeaders(
                source: source,
                artifactRootDirectory: root
            )
            Issue.record("generatePrivateHeaders unexpectedly returned a result")
        } catch let error as PrivateHeaderGeneration.GenerationError {
            #expect(
                error == .notImplemented(
                    plan: PrivateHeaderGeneration.makePlan(
                        source: source,
                        artifactRootDirectory: root
                    )
                )
            )
        }
    }
}
