import Foundation
import Testing

@testable import PrivateHeaderKitCore

@Suite
struct PrivateHeaderGenerationLeaseTests {
  @Test func contentionFailsFastAndLockCanBeAcquiredAfterRelease() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PrivateHeaderGenerationLeaseTests-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let lockURL = root.appendingPathComponent("generation.lock")
    let acquired = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let holder = Task {
      try await GenerationLease.withExclusiveLease(at: lockURL) {
        acquired.continuation.yield()
        acquired.continuation.finish()
        for await _ in release.stream { break }
      }
    }
    for await _ in acquired.stream { break }

    do {
      _ = try await GenerationLease.withExclusiveLease(at: lockURL) { true }
      Issue.record("contended generation lease was unexpectedly acquired")
    } catch let error as GenerationLease.LeaseError {
      #expect(error == .unavailable(path: lockURL.path))
    }

    release.continuation.yield()
    release.continuation.finish()
    try await holder.value
    #expect(try await GenerationLease.withExclusiveLease(at: lockURL) { true })
  }
}
