import Foundation
import Testing

@testable import PrivateHeaderKitCore

@Suite
struct PrivateHeaderGenerationTests {
  @Test func sourceLabelHasStableDisplayAndDirectoryForms() throws {
    let source = try PrivateHeaderGeneration.Source(
      platform: .iOS,
      version: "27.0",
      build: "24A5355q"
    )
    #expect(source.label.displayName == "iOS 27.0 (24A5355q)")
    #expect(source.label.directoryName == "iOS27.0(24A5355q)")
  }

  @Test func sourceRejectsUnsafePathComponents() {
    #expect(throws: PrivateHeaderGeneration.Source.ValidationError.self) {
      _ = try PrivateHeaderGeneration.Source(platform: .iOS, version: "../27.0")
    }
    #expect(throws: PrivateHeaderGeneration.Source.ValidationError.self) {
      _ = try PrivateHeaderGeneration.Source(platform: .iOS, version: "27.0", build: "24A/1")
    }
  }

  @Test func oneOutputRootDerivesArtifactAndStateIdentity() throws {
    let source = try PrivateHeaderGeneration.Source(
      platform: .macOS, version: "16.0", build: "25A000")
    let output = PrivateHeaderGeneration.Output(
      baseDirectory: URL(fileURLWithPath: "/tmp/PrivateHeaderKit", isDirectory: true)
    )
    let plan = PrivateHeaderGeneration.makePlan(source: source, output: output)

    #expect(plan.artifactDirectory.path == "/tmp/PrivateHeaderKit/macOS16.0(25A000)")
    #expect(plan.stateDirectory.path == "/tmp/PrivateHeaderKit/.state/macOS16.0(25A000)")
    #expect(
      plan.databaseURL.path == "/tmp/PrivateHeaderKit/.state/macOS16.0(25A000)/generation.sqlite")
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
