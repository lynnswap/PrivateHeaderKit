import Foundation
import PrivateHeaderKitHelperProtocol
import Testing
@testable import PrivateHeaderKitCore

struct PrivateHeaderGenerationApplicationTests {
  @Test func applicationIdentityTracksBuildAndImageInsteadOfProcessLocation() throws {
    let first = try identity()
    let relocated = try identity(address: 0x5000, path: "/Applications/Relocated.app/Executable")
    #expect(first == relocated)
    #expect(first.storageIdentifier == relocated.storageIdentifier)
    #expect(first.storageIdentifier != (try identity(version: "2.0")).storageIdentifier)
    #expect(first.storageIdentifier != (try identity(build: "2")).storageIdentifier)
    #expect(first.storageIdentifier != (try identity(cpuSubtype: 2)).storageIdentifier)
    #expect(first.storageIdentifier != (try identity(uuid: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!)).storageIdentifier)
    #expect(first.storageIdentifier != (try identity(bundleIdentifier: "com.example.Other")).storageIdentifier)
  }

  @Test func applicationResumeIgnoresConnectionAndRecoveredInputLocation() throws {
    let fixture = try ApplicationGenerationFixture()
    defer { fixture.cleanup() }
    func fingerprint(destination: String, directory: String, includesBinary: Bool) throws -> String {
      let mode = PrivateHeaderGeneration.RawDumping.ExecutionMode.ssh(destination: destination, directory: directory)
      let application = PrivateHeaderGeneration.ApplicationSourceSnapshot(
        identity: fixture.identity, recoveredBinaryPath: directory + "/Executable", localBinaryURL: fixture.binary
      )
      let plan = fixture.plan(application: application, mode: mode, includesBinary: includesBinary)
      return PrivateHeaderGeneration.GenerationExecutor.planFingerprint(
        plan, canonicalOutputBase: fixture.output.baseDirectory, executionMode: mode, sharedCacheCohort: nil
      )
    }
    let first = try fingerprint(destination: "device", directory: "/tmp/first", includesBinary: false)
    #expect(first == (try fingerprint(destination: "vphone", directory: "/tmp/second", includesBinary: false)))
    #expect(first != (try fingerprint(destination: "device", directory: "/tmp/third", includesBinary: true)))
  }

  @Test func applicationUsesNormalGenerationAndPublishesDeclaredAnalysisBinary() async throws {
    let fixture = try ApplicationGenerationFixture()
    defer { fixture.cleanup() }
    let application = fixture.application
    let executor = fixture.executor(contents: "// application fixture\n", status: 0)
    let plan = fixture.plan(application: application, includesBinary: true)
    let result = try await executor.run(try await executor.prepare(plan))
    #expect(result.summary.status == .completed)
    #expect(result.summary.targetCounts.completed == 1)
    let artifactRoot = "Applications/" + fixture.identity.storageIdentifier + "/Headers"
    #expect(try String(contentsOf: plan.artifactDirectory.appendingPathComponent(artifactRoot + "/Generated.h"), encoding: .utf8) == "// application fixture\n")
    #expect(try Data(contentsOf: plan.artifactDirectory.appendingPathComponent(artifactRoot + "/Analysis/Executable.macho")) == Data("analysis fixture".utf8))
  }

  @Test func partialApplicationGenerationPreservesPreviouslyPublishedArtifacts() async throws {
    let fixture = try ApplicationGenerationFixture()
    defer { fixture.cleanup() }
    let plan = fixture.plan(application: fixture.application)
    let first = fixture.executor(contents: "// successful fixture\n", status: 0)
    _ = try await first.run(try await first.prepare(plan))
    let failed = fixture.executor(contents: "// incomplete fixture\n", status: 1)
    do {
      _ = try await failed.run(try await failed.prepare(plan))
      Issue.record("partial application generation unexpectedly succeeded")
    } catch PrivateHeaderGeneration.GenerationError.runFailed(let failure) {
      #expect(failure.summary.status == .partial)
      #expect(failure.summary.targetCounts.partial == 1)
    }
    let path = "Applications/" + fixture.identity.storageIdentifier + "/Headers/Generated.h"
    #expect(try String(contentsOf: plan.artifactDirectory.appendingPathComponent(path), encoding: .utf8) == "// successful fixture\n")
  }

  private func identity(
    bundleIdentifier: String = "com.example.Sample", version: String? = "1.0", build: String? = "1",
    cpuSubtype: Int32 = 0, address: UInt64 = 0x1000, path: String = "/Applications/Sample.app/Executable",
    uuid: UUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
  ) throws -> PrivateHeaderGeneration.ApplicationIdentity {
    try .init(bundleIdentifier: bundleIdentifier, version: version, build: build,
      image: .init(loadAddress: address, path: path, uuid: uuid, cpuType: 16777228, cpuSubtype: cpuSubtype, fileType: 2))
  }
}

private struct ApplicationGenerationFixture: Sendable {
  let root: URL
  let binary: URL
  let output: PrivateHeaderGeneration.Output
  let identity: PrivateHeaderGeneration.ApplicationIdentity

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("ApplicationGenerationTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    binary = root.appendingPathComponent("Executable.macho")
    try Data("analysis fixture".utf8).write(to: binary)
    output = .init(baseDirectory: root.appendingPathComponent("Output"))
    identity = try .init(bundleIdentifier: "com.example.Sample", version: "1.0", build: "1", image: .init(
      loadAddress: 0x1000, path: "/Applications/Sample.app/Executable", uuid: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
      cpuType: 16777228, cpuSubtype: 0, fileType: 2
    ))
  }

  var application: PrivateHeaderGeneration.ApplicationSourceSnapshot {
    .init(identity: identity, recoveredBinaryPath: "/tmp/owned/Executable", localBinaryURL: binary)
  }

  func plan(
    application: PrivateHeaderGeneration.ApplicationSourceSnapshot,
    mode: PrivateHeaderGeneration.RawDumping.ExecutionMode = .ssh(destination: "device", directory: "/tmp/owned"),
    includesBinary: Bool = false
  ) -> PrivateHeaderGeneration.Plan {
    PrivateHeaderGeneration.makePlan(
      source: try! .init(platform: .iOS, version: "26.0", build: "23A100", metadataIsSeed: false, imageVariant: .iPhoneOSApplication(identity)),
      output: output, options: .init(
        systemRoot: URL(fileURLWithPath: "/"), helperURLs: .init(host: root.appendingPathComponent("helper"), simulator: root.appendingPathComponent("helper")),
        executionMode: mode, applicationSource: application, includesAnalysisBinary: includesBinary
      )
    )
  }

  func executor(contents: String, status: Int32) -> PrivateHeaderGeneration.GenerationExecutor {
    let logicalPath = application.logicalImagePath
    return .init(rawDumpRunner: { invocation in
      #expect(!invocation.command.contains("-c"))
      #expect(!invocation.command.contains("-R"))
      #expect(invocation.command.last?.contains("--image-path") == true)
      let path = String(URL(fileURLWithPath: logicalPath).deletingLastPathComponent().path.dropFirst()) + "/Headers"
      let directory = invocation.stagingOutputDirectory.appendingPathComponent(path)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try contents.write(to: directory.appendingPathComponent("Generated.h"), atomically: true, encoding: .utf8)
      return .init(terminationStatus: status, failureSummary: status == 0 ? nil : "fixture raw failure")
    }, sharedCacheInventoryRunner: { _ in
      Issue.record("application FILE parsing must not inventory the shared cache")
      return Data()
    })
  }

  func cleanup() { try? FileManager.default.removeItem(at: root) }
}
