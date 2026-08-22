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
    #expect(source.artifactDirectoryName == "27.0_beta_24A5355q")
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
    #expect(!source.artifactDirectoryName.contains("_beta_"))
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

  @Test func releaseMetadataOwnsBetaClassificationInsteadOfBuildSuffix() throws {
    let rapidSecurityResponse = try PrivateHeaderGeneration.Source(
      platform: .iOS,
      version: "16.4.1",
      build: "20E772520a",
      metadataIsSeed: false
    )
    let betaWithoutSuffix = try PrivateHeaderGeneration.Source(
      platform: .iOS,
      version: "27.0",
      build: "24A123",
      metadataIsSeed: true
    )

    #expect(rapidSecurityResponse.releaseChannel == .release)
    #expect(rapidSecurityResponse.label.displayName == "iOS 16.4.1 (20E772520a)")
    #expect(rapidSecurityResponse.artifactDirectoryName == "16.4.1_20E772520a")
    #expect(betaWithoutSuffix.releaseChannel == .beta)
    #expect(betaWithoutSuffix.label.displayName == "iOS 27.0 beta (24A123)")
    #expect(betaWithoutSuffix.artifactDirectoryName == "27.0_beta_24A123")
  }

  @Test func seedSourceRequiresAnExactBuild() {
    #expect(throws: PrivateHeaderGeneration.Source.ValidationError.self) {
      _ = try PrivateHeaderGeneration.Source(
        platform: .iOS,
        version: "27.0",
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
      options: .init()
    )

    #expect(
      plan.artifactDirectory.path
        == "/tmp/PrivateHeaderKit/generated-headers/macOS/16.0_25A000")
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
      )
    )
    let second = PrivateHeaderGeneration.makePlan(
      source: source,
      output: output,
      options: .init(
        systemRoot: URL(fileURLWithPath: "/foo\nheaders\n/runtime", isDirectory: true),
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

  @Test func simulatorFingerprintUsesProducerAndRuntimeIdentityNotExecutionLocators() throws {
    let source = try PrivateHeaderGeneration.Source(
      platform: .iOS,
      version: "27.0",
      build: "24A5355q",
      metadataIsSeed: true
    )
    let output = PrivateHeaderGeneration.Output(
      baseDirectory: URL(fileURLWithPath: "/tmp/PrivateHeaderKit", isDirectory: true)
    )
    let runtime = PrivateHeaderGeneration.RawDumping.SimulatorRuntimeIdentity(
      version: "27.0",
      build: "24A5355q",
      identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
      runtimeRoot: "/Runtime"
    )
    let firstMode = PrivateHeaderGeneration.RawDumping.ExecutionMode.simulator(
      deviceUDID: "11111111-2222-3333-4444-555555555555",
      sourceRuntimeRoot: "/Runtime",
      runtime: runtime
    )
    let secondMode = PrivateHeaderGeneration.RawDumping.ExecutionMode.simulator(
      deviceUDID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
      sourceRuntimeRoot: "/Runtime",
      runtime: runtime
    )
    let firstPlan = PrivateHeaderGeneration.makePlan(
      source: source,
      output: output,
      options: .init(
        systemRoot: URL(fileURLWithPath: "/Runtime", isDirectory: true),
        helperURLs: .init(
          host: URL(fileURLWithPath: "/prepared/first/host"),
          simulator: URL(fileURLWithPath: "/prepared/first/simulator")
        ),
        executionMode: firstMode,
        producerVersion: "v1.0.0"
      )
    )
    let relocatedPlan = PrivateHeaderGeneration.makePlan(
      source: source,
      output: output,
      options: .init(
        systemRoot: URL(fileURLWithPath: "/Runtime", isDirectory: true),
        helperURLs: .init(
          host: URL(fileURLWithPath: "/prepared/second/host"),
          simulator: URL(fileURLWithPath: "/prepared/second/simulator")
        ),
        executionMode: secondMode,
        producerVersion: "v1.0.0"
      )
    )
    let changedProducerPlan = PrivateHeaderGeneration.makePlan(
      source: source,
      output: output,
      options: .init(
        systemRoot: URL(fileURLWithPath: "/Runtime", isDirectory: true),
        helperURLs: relocatedPlan.options.helperURLs,
        executionMode: secondMode,
        producerVersion: "v1.1.0"
      )
    )
    let outputBase = output.baseDirectory.standardizedFileURL
    let first = PrivateHeaderGeneration.GenerationExecutor.planFingerprint(
      firstPlan,
      canonicalOutputBase: outputBase,
      executionMode: firstMode,
      sharedCacheCohort: nil
    )
    let relocated = PrivateHeaderGeneration.GenerationExecutor.planFingerprint(
      relocatedPlan,
      canonicalOutputBase: outputBase,
      executionMode: secondMode,
      sharedCacheCohort: nil
    )
    let changedProducer = PrivateHeaderGeneration.GenerationExecutor.planFingerprint(
      changedProducerPlan,
      canonicalOutputBase: outputBase,
      executionMode: secondMode,
      sharedCacheCohort: nil
    )
    let changedRuntime = PrivateHeaderGeneration.GenerationExecutor.planFingerprint(
      relocatedPlan,
      canonicalOutputBase: outputBase,
      executionMode: .simulator(
        deviceUDID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
        sourceRuntimeRoot: "/Runtime",
        runtime: .init(
          version: "27.0",
          build: "24A9999z",
          identifier: runtime.identifier,
          runtimeRoot: runtime.runtimeRoot
        )
      ),
      sharedCacheCohort: nil
    )

    #expect(first == relocated)
    #expect(first != changedProducer)
    #expect(first != changedRuntime)
  }
}
