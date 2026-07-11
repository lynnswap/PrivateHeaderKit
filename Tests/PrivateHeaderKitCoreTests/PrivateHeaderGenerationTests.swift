import Foundation
import Testing

@testable import PrivateHeaderKitCore

@Suite
struct PrivateHeaderGenerationTests {
  @Test func sourceKeepsPresentationSeparateFromStorageIdentity() throws {
    let source = try PrivateHeaderGeneration.Source(
      platform: .iOS,
      version: "27.0",
      build: "24A5355q"
    )
    #expect(source.label.displayName == "iOS 27.0 (24A5355q)")
    #expect(source.storageIdentifier == "ios-v1-27.0-b1-24~415355~71")
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
    let precomposed = try PrivateHeaderGeneration.Source(platform: .iOS, version: "é")
    let decomposed = try PrivateHeaderGeneration.Source(platform: .iOS, version: "e\u{301}")

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

  @Test func oneOutputRootDerivesArtifactAndStateIdentity() throws {
    let source = try PrivateHeaderGeneration.Source(
      platform: .macOS, version: "16.0", build: "25A000")
    let output = PrivateHeaderGeneration.Output(
      baseDirectory: URL(fileURLWithPath: "/tmp/PrivateHeaderKit", isDirectory: true)
    )
    let plan = PrivateHeaderGeneration.makePlan(source: source, output: output)

    #expect(
      plan.artifactDirectory.path == "/tmp/PrivateHeaderKit/macos-v1-16.0-b1-25~41000")
    #expect(
      plan.stateDirectory.path == "/tmp/PrivateHeaderKit/.state/macos-v1-16.0-b1-25~41000")
    #expect(
      plan.databaseURL.path
        == "/tmp/PrivateHeaderKit/.state/macos-v1-16.0-b1-25~41000/generation.sqlite")
  }

  @Test func topLevelAPIRequiresInjectedExecutionConfiguration() async throws {
    let source = try PrivateHeaderGeneration.Source(platform: .macOS, version: "16.0")
    let output = PrivateHeaderGeneration.Output(
      baseDirectory: URL(fileURLWithPath: "/tmp/PrivateHeaderKit"))
    do {
      _ = try await PrivateHeaderGeneration.generatePrivateHeaders(
        source: source,
        output: output,
        rawDumpRunner: { _ in .init(terminationStatus: 0) }
      )
      Issue.record("generation unexpectedly ran without systemRoot")
    } catch let error as PrivateHeaderGeneration.GenerationError {
      #expect(error == .missingExecutionConfiguration("systemRoot"))
    }
  }
}
