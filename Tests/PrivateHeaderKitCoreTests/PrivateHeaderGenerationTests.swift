import Foundation
import Testing

@testable import PrivateHeaderKitCore

@Suite
struct PrivateHeaderGenerationTests {
  @Test func sourceKeepsPresentationSeparateFromStorageIdentity() throws {
    let source = try PrivateHeaderGeneration.Source(
      platform: .iOS,
      version: "27.0",
      build: "24A5355q",
      metadataIsSeed: true
    )
    #expect(source.label.displayName == "iOS 27.0 beta (24A5355q)")
    #expect(source.artifactDirectoryName == "27.0 beta (24A5355q)")
    #expect(source.storageIdentifier == "ios-v1-27.0-b1-24~415355~71")
  }

  @Test func watchOSSourceHasItsOwnStableStorageIdentity() throws {
    let source = try PrivateHeaderGeneration.Source(
      platform: .watchOS,
      version: "27.0",
      build: "24R5325f",
      metadataIsSeed: true
    )

    #expect(source.label.displayName == "watchOS 27.0 beta (24R5325f)")
    #expect(source.storageIdentifier == "watchos-v1-27.0-b1-24~525325~66")
  }

  @Test func storageIdentityDistinguishesAmbiguousLabelsAndFilesystemAliases() throws {
    let versionContainsBuild = try PrivateHeaderGeneration.Source(
      platform: .iOS,
      version: "17.0(A)",
      metadataIsSeed: false
    )
    let separateBuild = try PrivateHeaderGeneration.Source(
      platform: .iOS,
      version: "17.0",
      build: "A",
      metadataIsSeed: false
    )
    let lowercaseBuild = try PrivateHeaderGeneration.Source(
      platform: .iOS,
      version: "17.0",
      build: "a",
      metadataIsSeed: false
    )
    let literalEscape = try PrivateHeaderGeneration.Source(
      platform: .iOS,
      version: "17.0",
      build: "~41",
      metadataIsSeed: false
    )

    #expect(versionContainsBuild.storageIdentifier != separateBuild.storageIdentifier)
    #expect(separateBuild.storageIdentifier != lowercaseBuild.storageIdentifier)
    #expect(separateBuild.storageIdentifier != literalEscape.storageIdentifier)
    #expect(versionContainsBuild.artifactDirectoryName != separateBuild.artifactDirectoryName)
    #expect(separateBuild.artifactDirectoryName != lowercaseBuild.artifactDirectoryName)
    #expect(separateBuild.artifactDirectoryName != literalEscape.artifactDirectoryName)
  }

  @Test func sourceCanonicalizesUnicodeBeforeDerivingStorageIdentity() throws {
    let precomposed = try PrivateHeaderGeneration.Source(
      platform: .iOS, version: "é", metadataIsSeed: false)
    let decomposed = try PrivateHeaderGeneration.Source(
      platform: .iOS, version: "e\u{301}", metadataIsSeed: false)

    #expect(precomposed == decomposed)
    #expect(decomposed.version == "é")
    #expect(precomposed.storageIdentifier == decomposed.storageIdentifier)
  }

  @Test func sourceRejectsStorageIdentityLongerThanAPathComponent() {
    #expect(throws: PrivateHeaderGeneration.Source.ValidationError.self) {
      _ = try PrivateHeaderGeneration.Source(
        platform: .iOS,
        version: String(repeating: "A", count: 82),
        metadataIsSeed: false
      )
    }
  }

  @Test func sourceEscapesPathSeparatorsAndInvalidBetaShapedBuilds() throws {
    let source = try PrivateHeaderGeneration.Source(
      platform: .iOS,
      version: "../27/0\0",
      build: "not-a-build",
      metadataIsSeed: false
    )

    #expect(!source.artifactDirectoryName.contains("/"))
    #expect(!source.artifactDirectoryName.contains("\0"))
    #expect(!source.artifactDirectoryName.contains(" beta"))
  }

  @Test func sourceRejectsArtifactDirectoryNameLongerThanAPathComponent() {
    #expect(throws: PrivateHeaderGeneration.Source.ValidationError.self) {
      _ = try PrivateHeaderGeneration.Source(
        platform: .iOS,
        version: String(repeating: ".", count: 85) + "A",
        metadataIsSeed: false
      )
    }
  }

  @Test func sourceRejectsReleaseMetadataThatDisagreesWithBuildIdentity() {
    #expect(throws: PrivateHeaderGeneration.Source.ValidationError.self) {
      _ = try PrivateHeaderGeneration.Source(
        platform: .iOS,
        version: "27.0",
        build: "24A5390f",
        metadataIsSeed: false
      )
    }
    #expect(throws: PrivateHeaderGeneration.Source.ValidationError.self) {
      _ = try PrivateHeaderGeneration.Source(
        platform: .iOS,
        version: "27.0",
        build: "24A123",
        metadataIsSeed: true
      )
    }
  }

  @Test func oneOutputRootDerivesArtifactAndStateIdentity() throws {
    let source = try PrivateHeaderGeneration.Source(
      platform: .macOS, version: "16.0", build: "25A000", metadataIsSeed: false)
    let output = PrivateHeaderGeneration.Output(
      baseDirectory: URL(fileURLWithPath: "/tmp/PrivateHeaderKit", isDirectory: true)
    )
    let plan = PrivateHeaderGeneration.makePlan(
      source: source,
      output: output,
      options: .init(toolCompatibilityIdentity: "test")
    )

    #expect(
      plan.artifactDirectory.path
        == "/tmp/PrivateHeaderKit/generated-headers/macOS/16.0 (25A000)")
    #expect(
      plan.stateDirectory.path == "/tmp/PrivateHeaderKit/.state/macos-v1-16.0-b1-25~41000")
    #expect(
      plan.databaseURL.path
        == "/tmp/PrivateHeaderKit/.state/macos-v1-16.0-b1-25~41000/generation.sqlite")
  }

  @Test func distinctPlansWithEmbeddedNewlinesHaveDistinctFingerprints() throws {
    let source = try PrivateHeaderGeneration.Source(
      platform: .macOS, version: "16.0", metadataIsSeed: false)
    let output = PrivateHeaderGeneration.Output(
      baseDirectory: URL(fileURLWithPath: "/tmp/PrivateHeaderKit", isDirectory: true)
    )
    let first = PrivateHeaderGeneration.makePlan(
      source: source,
      output: output,
      options: .init(
        systemRoot: URL(fileURLWithPath: "/runtime", isDirectory: true),
        toolCompatibilityIdentity: "test"
      )
    )
    let second = PrivateHeaderGeneration.makePlan(
      source: source,
      output: output,
      options: .init(
        systemRoot: URL(fileURLWithPath: "/foo\nheaders\n/runtime", isDirectory: true),
        toolCompatibilityIdentity: "test"
      )
    )

    let firstFingerprint = PrivateHeaderGeneration.GenerationExecutor.planFingerprint(
      first,
      canonicalOutputBase: URL(
        fileURLWithPath: "/output\nheaders\n/foo",
        isDirectory: true
      ),
      executionMode: .host,
      sharedCacheCohort: nil
    )
    let secondFingerprint = PrivateHeaderGeneration.GenerationExecutor.planFingerprint(
      second,
      canonicalOutputBase: URL(fileURLWithPath: "/output", isDirectory: true),
      executionMode: .host,
      sharedCacheCohort: nil
    )

    #expect(firstFingerprint != secondFingerprint)
  }
}
