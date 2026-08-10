import Foundation
import Testing

import PrivateHeaderKitCore

@Suite
struct PrivateHeaderGenerationPlatformTests {
    @Test func generationExecutorAcceptsExplicitPlatformNeutralRunners() {
        let executor = PrivateHeaderGeneration.GenerationExecutor(
            rawDumpRunner: { _ in
                PrivateHeaderGeneration.RawDumping.Result(terminationStatus: 0)
            },
            sharedCacheInventoryRunner: { _ in Data() }
        )

        _ = executor
    }
}

@Suite
struct PrivateHeaderGenerationLabelTests {
    @Test func iOSSourceKeepsPresentationSeparateFromStorageIdentity() throws {
        let source = try PrivateHeaderGeneration.Source(
            platform: .iOS,
            version: "27.0",
            build: "24A5355q"
        )

        #expect(source.label.displayName == "iOS 27.0 (24A5355q)")
        #expect(source.storageIdentifier == "ios-v1-27.0-b1-24~415355~71")
        #expect(source.label.description == "iOS 27.0 (24A5355q)")
    }

    @Test func macOSSourceUsesVersionedStorageIdentity() throws {
        let source = try PrivateHeaderGeneration.Source(
            platform: .macOS,
            version: "16.0",
            build: "25A5279m"
        )

        #expect(source.label.displayName == "macOS 16.0 (25A5279m)")
        #expect(source.storageIdentifier == "macos-v1-16.0-b1-25~415279~6d")
    }

    @Test func sourceLabelOmitsEmptyBuild() throws {
        let source = try PrivateHeaderGeneration.Source(
            platform: .iOS,
            version: "27.0",
            build: ""
        )

        #expect(source.label.displayName == "iOS 27.0")
        #expect(source.storageIdentifier == "ios-v1-27.0-b0")
    }

    @Test func storageIdentityDistinguishesAmbiguousLabelsAndFilesystemAliases() throws {
        let versionContainsBuild = try PrivateHeaderGeneration.Source(
            platform: .iOS,
            version: "17.0(A)"
        )
        let separateBuild = try PrivateHeaderGeneration.Source(
            platform: .iOS,
            version: "17.0",
            build: "A"
        )
        let lowercaseBuild = try PrivateHeaderGeneration.Source(
            platform: .iOS,
            version: "17.0",
            build: "a"
        )
        let literalEscape = try PrivateHeaderGeneration.Source(
            platform: .iOS,
            version: "17.0",
            build: "~41"
        )

        #expect(versionContainsBuild.storageIdentifier != separateBuild.storageIdentifier)
        #expect(separateBuild.storageIdentifier != lowercaseBuild.storageIdentifier)
        #expect(separateBuild.storageIdentifier != literalEscape.storageIdentifier)
    }

    @Test func sourceCanonicalizesUnicodeBeforeDerivingStorageIdentity() throws {
        let precomposed = try PrivateHeaderGeneration.Source(
            platform: .iOS,
            version: "é"
        )
        let decomposed = try PrivateHeaderGeneration.Source(
            platform: .iOS,
            version: "e\u{301}"
        )

        #expect(precomposed == decomposed)
        #expect(decomposed.version == "é")
        #expect(precomposed.storageIdentifier == decomposed.storageIdentifier)
    }

    @Test func sourceRejectsStorageIdentityLongerThanAPathComponent() {
        #expect(throws: PrivateHeaderGeneration.Source.ValidationError.self) {
            _ = try PrivateHeaderGeneration.Source(
                platform: .iOS,
                version: String(repeating: "A", count: 82)
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
        #expect(
            plan.artifactDirectory.path
                == "/tmp/PrivateHeaderKit/ios-v1-27.0-b1-24~415355~71"
        )
        #expect(
            plan.stateDirectory.path
                == "/tmp/PrivateHeaderKit/.state/ios-v1-27.0-b1-24~415355~71"
        )
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

        #expect(
            plan.artifactDirectory.path
                == "/tmp/PrivateHeaderKit/generated-headers/ios-v1-27.0-b1-24~415355~71"
        )
        #expect(
            plan.stateDirectory.path
                == "/tmp/PrivateHeaderKit/.state/ios-v1-27.0-b1-24~415355~71"
        )
    }

    #if os(macOS)
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
    #endif
}
