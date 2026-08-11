import Foundation
import Testing

@testable import PrivateHeaderKitCore

@Suite
struct PrivateHeaderGenerationArtifactReplacementTests {
  @Test func applyFailureRestoresTheEntirePreviousTarget() throws {
    let fixture = try ReplacementFixture()
    defer { fixture.cleanup() }
    let replacement = try fixture.prepareReplacement()
    let fileManager = FailingOnceRemovalFileManager(
      failingPath: fixture.liveURL("Frameworks/Foo/Headers/Removed.h").path
    )

    #expect(throws: InjectedReplacementFailure.self) {
      try fixture.store.applyReplacement(replacement, fileManager: fileManager)
    }

    #expect(try fixture.contents("Frameworks/Foo/Headers/Keep.h") == "old-keep")
    #expect(try fixture.contents("Frameworks/Foo/Headers/Removed.h") == "old-removed")
    #expect(!FileManager.default.fileExists(
      atPath: fixture.liveURL("Frameworks/Foo/Headers/New.h").path
    ))
    try fixture.store.finalizeReplacement(replacement)
  }

  @Test func pendingReplacementCanRollbackAfterProcessRestart() throws {
    let fixture = try ReplacementFixture()
    defer { fixture.cleanup() }
    let replacement = try fixture.prepareReplacement()
    try fixture.store.applyReplacement(replacement)
    #expect(try fixture.contents("Frameworks/Foo/Headers/Keep.h") == "new-keep")

    let recovered = try #require(
      PrivateHeaderGeneration.ArtifactStore.pendingReplacements(
        in: fixture.replacementsRoot,
        artifactRoot: fixture.liveRoot
      ).only
    )
    try fixture.store.rollbackReplacement(recovered)
    try fixture.store.finalizeReplacement(recovered)

    #expect(try fixture.contents("Frameworks/Foo/Headers/Keep.h") == "old-keep")
    #expect(try fixture.contents("Frameworks/Foo/Headers/Removed.h") == "old-removed")
    #expect(!FileManager.default.fileExists(
      atPath: fixture.liveURL("Frameworks/Foo/Headers/New.h").path
    ))
  }
}

private struct ReplacementFixture {
  let root: URL
  let liveRoot: URL
  let stagingRoot: URL
  let replacementsRoot: URL
  let store: PrivateHeaderGeneration.ArtifactStore

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PrivateHeaderGenerationArtifactReplacementTests-\(UUID().uuidString)",
      isDirectory: true
    )
    liveRoot = root.appendingPathComponent("live", isDirectory: true)
    stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
    replacementsRoot = root.appendingPathComponent("replacements", isDirectory: true)
    store = PrivateHeaderGeneration.ArtifactStore(artifactRoot: liveRoot)
    try write("old-keep", to: liveURL("Frameworks/Foo/Headers/Keep.h"))
    try write("old-removed", to: liveURL("Frameworks/Foo/Headers/Removed.h"))
    try write("new-keep", to: stagingRoot.appendingPathComponent("output/Headers/Keep.h"))
    try write("new", to: stagingRoot.appendingPathComponent("output/Headers/New.h"))
  }

  func prepareReplacement() throws -> PrivateHeaderGeneration.ArtifactStore.Replacement {
    let artifactRoot = try PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo")
    let incoming = try [
      PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo/Headers/Keep.h"),
      PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo/Headers/New.h"),
    ]
    let removing = try [
      PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo/Headers/Keep.h"),
      PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo/Headers/Removed.h"),
    ]
    let plan = try store.prepareCommit(
      stagingDirectory: stagingRoot,
      stagedSourceDirectory: stagingRoot.appendingPathComponent("output", isDirectory: true),
      artifactRoot: artifactRoot,
      artifacts: incoming
    )
    return try store.prepareReplacement(
      plan,
      removing: removing,
      runID: .init(rawValue: "run-replacement"),
      targetID: "framework:Foo.framework",
      at: replacementsRoot
        .appendingPathComponent("run-replacement", isDirectory: true)
        .appendingPathComponent("framework%3AFoo.framework", isDirectory: true)
    )
  }

  func liveURL(_ relativePath: String) -> URL {
    liveRoot.appendingPathComponent(relativePath, isDirectory: false)
  }

  func contents(_ relativePath: String) throws -> String {
    try String(contentsOf: liveURL(relativePath), encoding: .utf8)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }

  private func write(_ contents: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try contents.write(to: url, atomically: true, encoding: .utf8)
  }
}

private enum InjectedReplacementFailure: Error {
  case stop
}

private final class FailingOnceRemovalFileManager: FileManager, @unchecked Sendable {
  private let failingPath: String
  private var hasFailed = false

  init(failingPath: String) {
    self.failingPath = failingPath
    super.init()
  }

  override func removeItem(at URL: URL) throws {
    if URL.path == failingPath, !hasFailed {
      hasFailed = true
      throw InjectedReplacementFailure.stop
    }
    try super.removeItem(at: URL)
  }
}

private extension Array {
  var only: Element? {
    count == 1 ? self[0] : nil
  }
}
