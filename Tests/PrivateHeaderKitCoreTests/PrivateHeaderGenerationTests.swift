import Foundation
import Testing

import PrivateHeaderKitCore

@Suite
struct PrivateHeaderGenerationLabelTests {
    @Test func iOSSourceLabelUsesUserFacingDisplayAndCompactDirectoryNames() throws {
        let source = try PrivateHeaderGeneration.Source(
            platform: .iOS,
            version: "27.0",
            build: "24A5355q"
        )

        #expect(source.label.displayName == "iOS 27.0 (24A5355q)")
        #expect(source.label.directoryName == "iOS27.0(24A5355q)")
        #expect(source.label.description == "iOS 27.0 (24A5355q)")
    }

    @Test func macOSSourceLabelUsesUserFacingDisplayAndCompactDirectoryNames() throws {
        let source = try PrivateHeaderGeneration.Source(
            platform: .macOS,
            version: "16.0",
            build: "25A5279m"
        )

        #expect(source.label.displayName == "macOS 16.0 (25A5279m)")
        #expect(source.label.directoryName == "macOS16.0(25A5279m)")
    }

    @Test func sourceLabelOmitsEmptyBuild() throws {
        let source = try PrivateHeaderGeneration.Source(
            platform: .iOS,
            version: "27.0",
            build: ""
        )

        #expect(source.label.displayName == "iOS 27.0")
        #expect(source.label.directoryName == "iOS27.0")
    }

    @Test func sourceRejectsPathUnsafeVersionAndBuildComponents() throws {
        #expect(throws: PrivateHeaderGeneration.Source.ValidationError.self) {
            _ = try PrivateHeaderGeneration.Source(
                platform: .iOS,
                version: "../27.0",
                build: "24A5355q"
            )
        }

        #expect(throws: PrivateHeaderGeneration.Source.ValidationError.self) {
            _ = try PrivateHeaderGeneration.Source(
                platform: .iOS,
                version: "27.0",
                build: "24A/5355q"
            )
        }
    }
}

@Suite
struct PrivateHeaderGenerationPlanTests {
    @Test func customOutputBaseKeepsStateOutsideArtifactDirectoryAndUsesSourceLabelAsResumeKey() throws {
        let source = try PrivateHeaderGeneration.Source(
            platform: .iOS,
            version: "27.0",
            build: "24A5355q"
        )
        let root = URL(fileURLWithPath: "/tmp/PrivateHeaderKit", isDirectory: true)
        let output = PrivateHeaderGeneration.Output(baseDirectory: root)

        let plan = PrivateHeaderGeneration.makePlan(
            source: source,
            output: output
        )

        #expect(plan.source == source)
        #expect(plan.output == output)
        #expect(plan.artifactDirectory.path == "/tmp/PrivateHeaderKit/iOS27.0(24A5355q)")
        #expect(plan.stateDirectory.path == "/tmp/PrivateHeaderKit/.state/iOS27.0(24A5355q)")
        #expect(plan.target == .allAvailable)
    }

    @Test func defaultOutputCanSeparateArtifactAndStateBases() throws {
        let source = try PrivateHeaderGeneration.Source(
            platform: .iOS,
            version: "27.0",
            build: "24A5355q"
        )
        let root = URL(fileURLWithPath: "/tmp/PrivateHeaderKit", isDirectory: true)
        let output = PrivateHeaderGeneration.Output(
            artifactBaseDirectory: root.appendingPathComponent("generated-headers", isDirectory: true),
            stateBaseDirectory: root.appendingPathComponent(".state", isDirectory: true)
        )

        let plan = PrivateHeaderGeneration.makePlan(
            source: source,
            output: output
        )

        #expect(plan.artifactDirectory.path == "/tmp/PrivateHeaderKit/generated-headers/iOS27.0(24A5355q)")
        #expect(plan.stateDirectory.path == "/tmp/PrivateHeaderKit/.state/iOS27.0(24A5355q)")
    }

    @Test func generatePrivateHeadersRequiresExecutionConfiguration() async throws {
        let source = try PrivateHeaderGeneration.Source(
            platform: .macOS,
            version: "16.0",
            build: "25A5279m"
        )
        let output = PrivateHeaderGeneration.Output(
            baseDirectory: URL(fileURLWithPath: "/tmp/PrivateHeaderKit", isDirectory: true)
        )

        do {
            _ = try await PrivateHeaderGeneration.generatePrivateHeaders(
                source: source,
                output: output
            )
            Issue.record("generatePrivateHeaders unexpectedly returned a result")
        } catch let error as PrivateHeaderGeneration.GenerationError {
            #expect(error == .missingExecutionConfiguration("systemRoot"))
        }
    }

    @Test func topLevelGeneratePrivateHeadersRequiresExecutionConfiguration() async throws {
        let source = try PrivateHeaderGeneration.Source(
            platform: .macOS,
            version: "16.0",
            build: "25A5279m"
        )
        let output = PrivateHeaderGeneration.Output(
            baseDirectory: URL(fileURLWithPath: "/tmp/PrivateHeaderKit", isDirectory: true)
        )

        do {
            _ = try await generatePrivateHeaders(
                source: source,
                output: output
            )
            Issue.record("generatePrivateHeaders unexpectedly returned a result")
        } catch let error as PrivateHeaderGeneration.GenerationError {
            #expect(error == .missingExecutionConfiguration("systemRoot"))
        }
    }
}
