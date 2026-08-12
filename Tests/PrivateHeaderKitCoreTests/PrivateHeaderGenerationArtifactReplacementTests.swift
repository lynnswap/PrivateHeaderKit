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

  @Test func replacementRejectsUnsupportedManifestVersionWithoutMutation() throws {
    let fixture = try ReplacementFixture()
    defer { fixture.cleanup() }
    _ = try fixture.prepareReplacement()
    try fixture.rewriteManifest { manifest in
      manifest["version"] = 99
    }

    #expect(throws: PrivateHeaderGeneration.ArtifactStoreError.self) {
      _ = try PrivateHeaderGeneration.ArtifactStore.pendingReplacements(
        in: fixture.replacementsRoot,
        artifactRoot: fixture.liveRoot
      )
    }

    #expect(try fixture.contents("Frameworks/Foo/Headers/Keep.h") == "old-keep")
    #expect(try fixture.contents("Frameworks/Foo/Headers/Removed.h") == "old-removed")
    #expect(FileManager.default.fileExists(atPath: fixture.transactionDirectory.path))
  }

  @Test func replacementRejectsIncompleteVersionOneManifestWithoutMutation() throws {
    let fixture = try ReplacementFixture()
    defer { fixture.cleanup() }
    _ = try fixture.prepareReplacement()
    try fixture.rewriteManifest { manifest in
      manifest.removeValue(forKey: "incomingDigests")
    }

    #expect(throws: PrivateHeaderGeneration.ArtifactStoreError.self) {
      _ = try PrivateHeaderGeneration.ArtifactStore.pendingReplacements(
        in: fixture.replacementsRoot,
        artifactRoot: fixture.liveRoot
      )
    }

    #expect(try fixture.contents("Frameworks/Foo/Headers/Keep.h") == "old-keep")
    #expect(try fixture.contents("Frameworks/Foo/Headers/Removed.h") == "old-removed")
    #expect(FileManager.default.fileExists(atPath: fixture.transactionDirectory.path))
  }

  @Test func replacementSupportsFileToDirectoryTransition() throws {
    let fixture = try ReplacementFixture(
      existingFiles: ["Frameworks/Foo/Headers/Shape": "old"],
      incomingFiles: ["Frameworks/Foo/Headers/Shape/New.h": "new"]
    )
    defer { fixture.cleanup() }
    let replacement = try fixture.prepareReplacement()

    try fixture.store.applyReplacement(replacement)

    #expect(try fixture.contents("Frameworks/Foo/Headers/Shape/New.h") == "new")
    try fixture.store.finalizeReplacement(replacement)
  }

  @Test func replacementSupportsDirectoryToFileTransition() throws {
    let fixture = try ReplacementFixture(
      existingFiles: ["Frameworks/Foo/Headers/Shape/Old.h": "old"],
      incomingFiles: ["Frameworks/Foo/Headers/Shape": "new"]
    )
    defer { fixture.cleanup() }
    let replacement = try fixture.prepareReplacement()

    try fixture.store.applyReplacement(replacement)

    #expect(try fixture.contents("Frameworks/Foo/Headers/Shape") == "new")
    try fixture.store.finalizeReplacement(replacement)
  }

  @Test func shapeTransitionFailureRestoresThePreviousFile() throws {
    let fixture = try ReplacementFixture(
      existingFiles: ["Frameworks/Foo/Headers/Shape": "old"],
      incomingFiles: ["Frameworks/Foo/Headers/Shape/New.h": "new"]
    )
    defer { fixture.cleanup() }
    let replacement = try fixture.prepareReplacement()
    let fileManager = FailingOnceDirectoryCreationFileManager(
      failingPath: fixture.liveURL("Frameworks/Foo/Headers/Shape").path
    )

    #expect(throws: InjectedReplacementFailure.self) {
      try fixture.store.applyReplacement(replacement, fileManager: fileManager)
    }

    #expect(try fixture.contents("Frameworks/Foo/Headers/Shape") == "old")
    try fixture.store.finalizeReplacement(replacement)
  }

  @Test func directoryToFileFailurePreservesUnknownSiblingAndPreviousFile() throws {
    let fixture = try ReplacementFixture(
      existingFiles: ["Frameworks/Foo/Headers/Shape/Old.h": "old"],
      incomingFiles: ["Frameworks/Foo/Headers/Shape": "new"]
    )
    defer { fixture.cleanup() }
    try "keep".write(
      to: fixture.liveURL("Frameworks/Foo/Headers/Shape/Keep.txt"),
      atomically: true,
      encoding: .utf8
    )
    let replacement = try fixture.prepareReplacement()

    #expect(throws: PrivateHeaderGeneration.ArtifactStoreError.self) {
      try fixture.store.applyReplacement(replacement)
    }

    #expect(try fixture.contents("Frameworks/Foo/Headers/Shape/Old.h") == "old")
    #expect(try fixture.contents("Frameworks/Foo/Headers/Shape/Keep.txt") == "keep")
    try fixture.store.finalizeReplacement(replacement)
  }

  @Test func shapeTransitionCanRollbackAfterProcessRestart() throws {
    let fixture = try ReplacementFixture(
      existingFiles: ["Frameworks/Foo/Headers/Shape": "old"],
      incomingFiles: ["Frameworks/Foo/Headers/Shape/New.h": "new"]
    )
    defer { fixture.cleanup() }
    let replacement = try fixture.prepareReplacement()
    try fixture.store.applyReplacement(replacement)

    let recovered = try #require(
      PrivateHeaderGeneration.ArtifactStore.pendingReplacements(
        in: fixture.replacementsRoot,
        artifactRoot: fixture.liveRoot
      ).only
    )
    try fixture.store.rollbackReplacement(recovered)
    try fixture.store.finalizeReplacement(recovered)

    #expect(try fixture.contents("Frameworks/Foo/Headers/Shape") == "old")
  }

  @Test func rollbackRestoresArtifactsOutsideTheNewArtifactRoot() throws {
    let fixture = try ReplacementFixture(
      existingFiles: ["Frameworks/Foo/Headers/Old.h": "old"],
      incomingFiles: ["Frameworks/Foo.framework/Headers/New.h": "new"],
      artifactRoot: "Frameworks/Foo.framework"
    )
    defer { fixture.cleanup() }
    let replacement = try fixture.prepareReplacement()
    try fixture.store.applyReplacement(replacement)

    try fixture.store.rollbackReplacement(replacement)

    #expect(try fixture.contents("Frameworks/Foo/Headers/Old.h") == "old")
    #expect(!FileManager.default.fileExists(
      atPath: fixture.liveURL("Frameworks/Foo.framework/Headers/New.h").path
    ))
    try fixture.store.finalizeReplacement(replacement)
  }

  @Test func rollbackRestoresOpaqueFileClaimedByIncomingArtifact() throws {
    let path = "Frameworks/Foo/Headers/Claimed.h"
    let fixture = try ReplacementFixture(
      existingFiles: [path: "opaque"],
      incomingFiles: [path: "generated"]
    )
    defer { fixture.cleanup() }
    let replacement = try fixture.prepareReplacement(removing: [])
    try fixture.store.applyReplacement(replacement)

    try fixture.store.rollbackReplacement(replacement)
    try fixture.store.rollbackReplacement(replacement)

    #expect(try fixture.contents(path) == "opaque")
    try fixture.store.finalizeReplacement(replacement)
  }

  @Test func recoveryRejectsArtifactRootReplacedBySymlink() throws {
    let fixture = try ReplacementFixture()
    defer { fixture.cleanup() }
    let replacement = try fixture.prepareReplacement()
    try fixture.store.applyReplacement(replacement)
    let externalRoot = fixture.root.appendingPathComponent("external", isDirectory: true)
    try FileManager.default.createDirectory(
      at: externalRoot,
      withIntermediateDirectories: false
    )
    let sentinel = externalRoot.appendingPathComponent("sentinel")
    try "keep".write(to: sentinel, atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(at: fixture.liveRoot)
    try FileManager.default.createSymbolicLink(
      at: fixture.liveRoot,
      withDestinationURL: externalRoot
    )

    let recovered = try #require(
      PrivateHeaderGeneration.ArtifactStore.pendingReplacements(
        in: fixture.replacementsRoot,
        artifactRoot: fixture.liveRoot
      ).only
    )
    #expect(throws: PrivateHeaderGeneration.ArtifactStoreError.self) {
      try fixture.store.rollbackReplacement(recovered)
    }
    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep")
  }

  @Test func missingBackupFailsBeforeRollbackChangesLiveOutput() throws {
    let fixture = try ReplacementFixture()
    defer { fixture.cleanup() }
    let replacement = try fixture.prepareReplacement()
    try fixture.store.applyReplacement(replacement)
    try FileManager.default.removeItem(
      at: fixture.backupURL("Frameworks/Foo/Headers/Keep.h")
    )

    #expect(throws: PrivateHeaderGeneration.ArtifactStoreError.self) {
      try fixture.store.rollbackReplacement(replacement)
    }

    #expect(try fixture.contents("Frameworks/Foo/Headers/Keep.h") == "new-keep")
    #expect(try fixture.contents("Frameworks/Foo/Headers/New.h") == "new")
  }

  @Test func finalizeDisarmsManifestBeforeRecursiveCleanup() throws {
    let fixture = try ReplacementFixture()
    defer { fixture.cleanup() }
    let replacement = try fixture.prepareReplacement()
    let fileManager = FailingOnceRemovalFileManager(
      failingPath: fixture.transactionDirectory.path
    )

    #expect(throws: InjectedReplacementFailure.self) {
      try fixture.store.finalizeReplacement(replacement, fileManager: fileManager)
    }

    #expect(try PrivateHeaderGeneration.ArtifactStore.pendingReplacements(
      in: fixture.replacementsRoot,
      artifactRoot: fixture.liveRoot
    ).isEmpty)
  }

  @Test func rollbackPreservesUnknownDestinationCreatedAfterPreparation() throws {
    let fixture = try ReplacementFixture()
    defer { fixture.cleanup() }
    let replacement = try fixture.prepareReplacement()
    try "unknown".write(
      to: fixture.liveURL("Frameworks/Foo/Headers/New.h"),
      atomically: true,
      encoding: .utf8
    )

    try fixture.store.rollbackReplacement(replacement)

    #expect(try fixture.contents("Frameworks/Foo/Headers/New.h") == "unknown")
    #expect(try fixture.contents("Frameworks/Foo/Headers/Keep.h") == "old-keep")
    #expect(try fixture.contents("Frameworks/Foo/Headers/Removed.h") == "old-removed")
    try fixture.store.finalizeReplacement(replacement)
  }

  @Test func applyRejectsUnknownDestinationCreatedAfterPreparation() throws {
    let fixture = try ReplacementFixture()
    defer { fixture.cleanup() }
    let replacement = try fixture.prepareReplacement()
    try "unknown".write(
      to: fixture.liveURL("Frameworks/Foo/Headers/New.h"),
      atomically: true,
      encoding: .utf8
    )

    #expect(throws: PrivateHeaderGeneration.ArtifactStoreError.self) {
      try fixture.store.applyReplacement(replacement)
    }

    #expect(try fixture.contents("Frameworks/Foo/Headers/New.h") == "unknown")
    #expect(try fixture.contents("Frameworks/Foo/Headers/Keep.h") == "old-keep")
    #expect(try fixture.contents("Frameworks/Foo/Headers/Removed.h") == "old-removed")
    try fixture.store.finalizeReplacement(replacement)
  }

  @Test func applyRejectsOldOnlyFileCreatedAfterPreparation() throws {
    let fixture = try ReplacementFixture()
    defer { fixture.cleanup() }
    let oldOnly = try PrivateHeaderGeneration.ArtifactPath(
      "Frameworks/Foo/Headers/OldOnly.h"
    )
    _ = try fixture.prepareReplacement(removing: fixture.existingArtifacts + [oldOnly])
    try "unknown".write(
      to: fixture.liveURL(oldOnly.rawValue),
      atomically: true,
      encoding: .utf8
    )
    let replacement = try #require(
      PrivateHeaderGeneration.ArtifactStore.pendingReplacements(
        in: fixture.replacementsRoot,
        artifactRoot: fixture.liveRoot
      ).only
    )

    #expect(throws: PrivateHeaderGeneration.ArtifactStoreError.self) {
      try fixture.store.applyReplacement(replacement)
    }

    #expect(try fixture.contents(oldOnly.rawValue) == "unknown")
    #expect(try fixture.contents("Frameworks/Foo/Headers/Keep.h") == "old-keep")
    #expect(try fixture.contents("Frameworks/Foo/Headers/Removed.h") == "old-removed")
    #expect(!FileManager.default.fileExists(
      atPath: fixture.liveURL("Frameworks/Foo/Headers/New.h").path
    ))
    try fixture.store.finalizeReplacement(replacement)
  }

  @Test func applyRejectsOldOnlyDirectoryCreatedAfterPreparation() throws {
    let fixture = try ReplacementFixture()
    defer { fixture.cleanup() }
    let oldOnly = try PrivateHeaderGeneration.ArtifactPath(
      "Frameworks/Foo/Headers/OldOnly.h"
    )
    let replacement = try fixture.prepareReplacement(
      removing: fixture.existingArtifacts + [oldOnly]
    )
    try FileManager.default.createDirectory(
      at: fixture.liveURL(oldOnly.rawValue),
      withIntermediateDirectories: false
    )

    #expect(throws: PrivateHeaderGeneration.ArtifactStoreError.self) {
      try fixture.store.applyReplacement(replacement)
    }

    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(
      atPath: fixture.liveURL(oldOnly.rawValue).path,
      isDirectory: &isDirectory
    ))
    #expect(isDirectory.boolValue)
    #expect(try fixture.contents("Frameworks/Foo/Headers/Keep.h") == "old-keep")
    #expect(try fixture.contents("Frameworks/Foo/Headers/Removed.h") == "old-removed")
    #expect(!FileManager.default.fileExists(
      atPath: fixture.liveURL("Frameworks/Foo/Headers/New.h").path
    ))
    try fixture.store.finalizeReplacement(replacement)
  }

  @Test func replacementSupportsCaseOnlyPathTransition() throws {
    let fixture = try ReplacementFixture(
      existingFiles: ["Frameworks/Foo/Headers/Case.h": "old"],
      incomingFiles: ["Frameworks/Foo/Headers/case.h": "new"]
    )
    defer { fixture.cleanup() }
    let replacement = try fixture.prepareReplacement()

    try fixture.store.applyReplacement(replacement)
    #expect(try fixture.contents("Frameworks/Foo/Headers/case.h") == "new")
    try fixture.store.rollbackReplacement(replacement)

    #expect(try fixture.contents("Frameworks/Foo/Headers/Case.h") == "old")
    try fixture.store.finalizeReplacement(replacement)
  }

  @Test func rollbackBeforeApplyPreservesAnExistingEmptyDirectory() throws {
    let fixture = try ReplacementFixture(
      existingFiles: ["Frameworks/Foo/Headers/Old.h": "old"],
      incomingFiles: ["Frameworks/Foo/Headers/NewDir/New.h": "new"]
    )
    defer { fixture.cleanup() }
    let replacement = try fixture.prepareReplacement()
    let createdDirectory = fixture.liveURL("Frameworks/Foo/Headers/NewDir")
    try FileManager.default.createDirectory(
      at: createdDirectory,
      withIntermediateDirectories: true
    )

    try fixture.store.rollbackReplacement(replacement)

    #expect(FileManager.default.fileExists(atPath: createdDirectory.path))
    #expect(try fixture.contents("Frameworks/Foo/Headers/Old.h") == "old")
    try fixture.store.finalizeReplacement(replacement)
  }

  @Test func replacementSupportsCaseAliasedFileToDirectoryTransition() throws {
    let fixture = try ReplacementFixture(
      existingFiles: ["Frameworks/Foo/Headers/Shape": "old"],
      incomingFiles: ["Frameworks/Foo/headers/shape/New.h": "new"]
    )
    defer { fixture.cleanup() }
    let replacement = try fixture.prepareReplacement()

    try fixture.store.applyReplacement(replacement)
    #expect(try fixture.contents("Frameworks/Foo/headers/shape/New.h") == "new")
    try fixture.store.rollbackReplacement(replacement)

    #expect(try fixture.contents("Frameworks/Foo/Headers/Shape") == "old")
    try fixture.store.finalizeReplacement(replacement)
  }

  @Test func applyRejectsAChangedBackedUpLiveFileWithoutMutatingOutput() throws {
    let fixture = try ReplacementFixture()
    defer { fixture.cleanup() }
    let replacement = try fixture.prepareReplacement()
    try "user-edit".write(
      to: fixture.liveURL("Frameworks/Foo/Headers/Keep.h"),
      atomically: true,
      encoding: .utf8
    )

    #expect(throws: PrivateHeaderGeneration.ArtifactStoreError.self) {
      try fixture.store.applyReplacement(replacement)
    }
    try fixture.store.rollbackReplacement(replacement)

    #expect(try fixture.contents("Frameworks/Foo/Headers/Keep.h") == "user-edit")
    #expect(try fixture.contents("Frameworks/Foo/Headers/Removed.h") == "old-removed")
    #expect(!FileManager.default.fileExists(
      atPath: fixture.liveURL("Frameworks/Foo/Headers/New.h").path
    ))
    try fixture.store.finalizeReplacement(replacement)
  }

  @Test func rollbackRejectsAChangedInstalledFileBeforeMutatingOtherArtifacts() throws {
    let fixture = try ReplacementFixture()
    defer { fixture.cleanup() }
    let replacement = try fixture.prepareReplacement()
    try fixture.store.applyReplacement(replacement)
    try "user-edit".write(
      to: fixture.liveURL("Frameworks/Foo/Headers/New.h"),
      atomically: true,
      encoding: .utf8
    )

    #expect(throws: PrivateHeaderGeneration.ArtifactStoreError.self) {
      try fixture.store.rollbackReplacement(replacement)
    }

    #expect(try fixture.contents("Frameworks/Foo/Headers/Keep.h") == "new-keep")
    #expect(try fixture.contents("Frameworks/Foo/Headers/New.h") == "user-edit")
    #expect(!FileManager.default.fileExists(
      atPath: fixture.liveURL("Frameworks/Foo/Headers/Removed.h").path
    ))
  }

  @Test func rollbackRejectsATamperedBackupBeforeMutatingLiveOutput() throws {
    let fixture = try ReplacementFixture()
    defer { fixture.cleanup() }
    let replacement = try fixture.prepareReplacement()
    try fixture.store.applyReplacement(replacement)
    try "tampered".write(
      to: fixture.backupURL("Frameworks/Foo/Headers/Keep.h"),
      atomically: true,
      encoding: .utf8
    )

    #expect(throws: PrivateHeaderGeneration.ArtifactStoreError.self) {
      try fixture.store.rollbackReplacement(replacement)
    }

    #expect(try fixture.contents("Frameworks/Foo/Headers/Keep.h") == "new-keep")
    #expect(try fixture.contents("Frameworks/Foo/Headers/New.h") == "new")
  }

  @Test func rollbackRejectsALateSymlinkBeforeDeletingEarlierIncomingFiles() throws {
    let fixture = try ReplacementFixture()
    defer { fixture.cleanup() }
    let replacement = try fixture.prepareReplacement()
    try fixture.store.applyReplacement(replacement)
    let external = fixture.root.appendingPathComponent("external")
    try "external".write(to: external, atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(
      at: fixture.liveURL("Frameworks/Foo/Headers/New.h")
    )
    try FileManager.default.createSymbolicLink(
      at: fixture.liveURL("Frameworks/Foo/Headers/New.h"),
      withDestinationURL: external
    )

    #expect(throws: PrivateHeaderGeneration.ArtifactStoreError.self) {
      try fixture.store.rollbackReplacement(replacement)
    }

    #expect(try fixture.contents("Frameworks/Foo/Headers/Keep.h") == "new-keep")
    #expect(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: fixture.liveURL("Frameworks/Foo/Headers/New.h").path
      ) == external.path
    )
  }

  @Test func rollbackRejectsUnknownSiblingBeforeRemovingInstalledShapeContents() throws {
    let fixture = try ReplacementFixture(
      existingFiles: ["Frameworks/Foo/Headers/Shape": "old"],
      incomingFiles: ["Frameworks/Foo/Headers/Shape/New.h": "new"]
    )
    defer { fixture.cleanup() }
    let replacement = try fixture.prepareReplacement()
    try fixture.store.applyReplacement(replacement)
    try "unknown".write(
      to: fixture.liveURL("Frameworks/Foo/Headers/Shape/Keep.txt"),
      atomically: true,
      encoding: .utf8
    )

    #expect(throws: PrivateHeaderGeneration.ArtifactStoreError.self) {
      try fixture.store.rollbackReplacement(replacement)
    }

    #expect(try fixture.contents("Frameworks/Foo/Headers/Shape/New.h") == "new")
    #expect(try fixture.contents("Frameworks/Foo/Headers/Shape/Keep.txt") == "unknown")
  }

  @Test func applyRejectsArtifactRootReplacedByAnotherDirectory() throws {
    let fixture = try ReplacementFixture()
    defer { fixture.cleanup() }
    let replacement = try fixture.prepareReplacement()
    let originalRoot = fixture.root.appendingPathComponent("live-original", isDirectory: true)
    try FileManager.default.moveItem(at: fixture.liveRoot, to: originalRoot)
    try FileManager.default.createDirectory(
      at: fixture.liveRoot,
      withIntermediateDirectories: false
    )
    let sentinel = fixture.liveRoot.appendingPathComponent("sentinel")
    try "keep".write(to: sentinel, atomically: true, encoding: .utf8)

    #expect(throws: PrivateHeaderGeneration.ArtifactStoreError.self) {
      try fixture.store.applyReplacement(replacement)
    }

    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep")
    #expect(
      try String(
        contentsOf: originalRoot.appendingPathComponent("Frameworks/Foo/Headers/Keep.h"),
        encoding: .utf8
      ) == "old-keep"
    )
  }

  @Test func rollbackRejectsArtifactRootReplacedByAnotherDirectory() throws {
    let fixture = try ReplacementFixture()
    defer { fixture.cleanup() }
    let replacement = try fixture.prepareReplacement()
    try fixture.store.applyReplacement(replacement)
    let appliedRoot = fixture.root.appendingPathComponent("live-applied", isDirectory: true)
    try FileManager.default.moveItem(at: fixture.liveRoot, to: appliedRoot)
    try FileManager.default.createDirectory(
      at: fixture.liveRoot,
      withIntermediateDirectories: false
    )
    let sentinel = fixture.liveRoot.appendingPathComponent("sentinel")
    try "keep".write(to: sentinel, atomically: true, encoding: .utf8)

    #expect(throws: PrivateHeaderGeneration.ArtifactStoreError.self) {
      try fixture.store.rollbackReplacement(replacement)
    }

    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep")
    #expect(
      try String(
        contentsOf: appliedRoot.appendingPathComponent("Frameworks/Foo/Headers/Keep.h"),
        encoding: .utf8
      ) == "new-keep"
    )
  }

  @Test func unstartedReplacementCanBeDiscardedAfterRootAndStagingChanges() throws {
    let fixture = try ReplacementFixture()
    defer { fixture.cleanup() }
    _ = try fixture.prepareReplacement()
    try FileManager.default.removeItem(at: fixture.liveRoot)
    try FileManager.default.createDirectory(
      at: fixture.liveRoot,
      withIntermediateDirectories: false
    )
    let sentinel = fixture.liveRoot.appendingPathComponent("sentinel")
    try "keep".write(to: sentinel, atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(
      at: fixture.transactionDirectory.appendingPathComponent("incoming", isDirectory: true)
    )

    let recovered = try #require(
      PrivateHeaderGeneration.ArtifactStore.pendingReplacements(
        in: fixture.replacementsRoot,
        artifactRoot: fixture.liveRoot
      ).only
    )
    try fixture.store.rollbackReplacement(recovered)
    try fixture.store.finalizeReplacement(recovered)

    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep")
  }

  @Test func rollbackResumesAfterOneBackupWasAlreadyRestored() throws {
    let fixture = try ReplacementFixture()
    defer { fixture.cleanup() }
    let replacement = try fixture.prepareReplacement()
    try fixture.store.applyReplacement(replacement)
    try FileManager.default.removeItem(
      at: fixture.liveURL("Frameworks/Foo/Headers/Keep.h")
    )
    try FileManager.default.removeItem(
      at: fixture.liveURL("Frameworks/Foo/Headers/New.h")
    )
    try FileManager.default.copyItem(
      at: fixture.backupURL("Frameworks/Foo/Headers/Keep.h"),
      to: fixture.liveURL("Frameworks/Foo/Headers/Keep.h")
    )

    try fixture.store.rollbackReplacement(replacement)

    #expect(try fixture.contents("Frameworks/Foo/Headers/Keep.h") == "old-keep")
    #expect(try fixture.contents("Frameworks/Foo/Headers/Removed.h") == "old-removed")
    #expect(!FileManager.default.fileExists(
      atPath: fixture.liveURL("Frameworks/Foo/Headers/New.h").path
    ))
    try fixture.store.finalizeReplacement(replacement)
  }

  @Test func rollbackRestoresAnUnchangedArtifactWithMatchingIncomingDigest() throws {
    let path = "Frameworks/Foo/Headers/Keep.h"
    let fixture = try ReplacementFixture(
      existingFiles: [path: "same"],
      incomingFiles: [path: "same"]
    )
    defer { fixture.cleanup() }
    let replacement = try fixture.prepareReplacement()
    try fixture.store.applyReplacement(replacement)
    let recovered = try #require(
      PrivateHeaderGeneration.ArtifactStore.pendingReplacements(
        in: fixture.replacementsRoot,
        artifactRoot: fixture.liveRoot
      ).only
    )

    try fixture.store.rollbackReplacement(recovered)

    #expect(try fixture.contents(path) == "same")
    try fixture.store.finalizeReplacement(recovered)
  }

  @Test func rollbackRejectsTamperedDurableRestoreWithoutMutatingLiveOutput() throws {
    let fixture = try ReplacementFixture()
    defer { fixture.cleanup() }
    let replacement = try fixture.prepareReplacement()
    try fixture.store.applyReplacement(replacement)
    let partialRestore = fixture.transactionDirectory.appendingPathComponent(
      "restore/Frameworks/Foo/Headers/Keep.h"
    )
    try FileManager.default.createDirectory(
      at: partialRestore.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "partial".write(to: partialRestore, atomically: true, encoding: .utf8)

    #expect(throws: PrivateHeaderGeneration.ArtifactStoreError.self) {
      try fixture.store.rollbackReplacement(replacement)
    }

    #expect(try fixture.contents("Frameworks/Foo/Headers/Keep.h") == "new-keep")
    #expect(try fixture.contents("Frameworks/Foo/Headers/New.h") == "new")
    #expect(!FileManager.default.fileExists(
      atPath: fixture.liveURL("Frameworks/Foo/Headers/Removed.h").path
    ))
  }

  @Test func restorePayloadCopyFailureLeavesLiveOutputUntouchedAndUnarmed() throws {
    let fixture = try ReplacementFixture()
    defer { fixture.cleanup() }
    let fileManager = FailingOnceRestoreCopyFileManager()

    #expect(throws: InjectedReplacementFailure.self) {
      _ = try fixture.prepareReplacement(fileManager: fileManager)
    }

    #expect(try fixture.contents("Frameworks/Foo/Headers/Keep.h") == "old-keep")
    #expect(try fixture.contents("Frameworks/Foo/Headers/Removed.h") == "old-removed")
    #expect(!FileManager.default.fileExists(
      atPath: fixture.liveURL("Frameworks/Foo/Headers/New.h").path
    ))
    #expect(!FileManager.default.fileExists(atPath: fixture.transactionDirectory.path))
  }

  @Test func replacementRejectsCrossVolumeTransactionBeforeMutatingLiveOutput() throws {
    let fixture = try ReplacementFixture()
    defer { fixture.cleanup() }
    let fileManager = DifferentTransactionDeviceFileManager()

    #expect(throws: PrivateHeaderGeneration.ArtifactStoreError.self) {
      _ = try fixture.prepareReplacement(fileManager: fileManager)
    }

    #expect(try fixture.contents("Frameworks/Foo/Headers/Keep.h") == "old-keep")
    #expect(try fixture.contents("Frameworks/Foo/Headers/Removed.h") == "old-removed")
    #expect(!FileManager.default.fileExists(
      atPath: fixture.liveURL("Frameworks/Foo/Headers/New.h").path
    ))
    #expect(!FileManager.default.fileExists(atPath: fixture.transactionDirectory.path))
  }

  @Test func replacementRejectsMissingExclusiveRenameBeforeMutatingLiveOutput() throws {
    let fixture = try ReplacementFixture()
    defer { fixture.cleanup() }

    #expect(throws: InjectedReplacementFailure.self) {
      _ = try fixture.prepareReplacement(exclusiveRename: { _, _ in
        throw InjectedReplacementFailure.stop
      })
    }

    #expect(try fixture.contents("Frameworks/Foo/Headers/Keep.h") == "old-keep")
    #expect(try fixture.contents("Frameworks/Foo/Headers/Removed.h") == "old-removed")
    #expect(!FileManager.default.fileExists(
      atPath: fixture.liveURL("Frameworks/Foo/Headers/New.h").path
    ))
    #expect(!FileManager.default.fileExists(atPath: fixture.transactionDirectory.path))
  }
}

private struct ReplacementFixture {
  let root: URL
  let liveRoot: URL
  let stagingRoot: URL
  let replacementsRoot: URL
  let store: PrivateHeaderGeneration.ArtifactStore
  let existingArtifacts: [PrivateHeaderGeneration.ArtifactPath]
  let incomingArtifacts: [PrivateHeaderGeneration.ArtifactPath]
  let artifactRoot: PrivateHeaderGeneration.ArtifactPath

  var transactionDirectory: URL {
    replacementsRoot
      .appendingPathComponent("run-replacement", isDirectory: true)
      .appendingPathComponent("framework%3AFoo.framework", isDirectory: true)
  }

  init(
    existingFiles: [String: String] = [
      "Frameworks/Foo/Headers/Keep.h": "old-keep",
      "Frameworks/Foo/Headers/Removed.h": "old-removed",
    ],
    incomingFiles: [String: String] = [
      "Frameworks/Foo/Headers/Keep.h": "new-keep",
      "Frameworks/Foo/Headers/New.h": "new",
    ],
    artifactRoot: String = "Frameworks/Foo"
  ) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PrivateHeaderGenerationArtifactReplacementTests-\(UUID().uuidString)",
      isDirectory: true
    )
    liveRoot = root.appendingPathComponent("live", isDirectory: true)
    stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
    replacementsRoot = root.appendingPathComponent("replacements", isDirectory: true)
    store = PrivateHeaderGeneration.ArtifactStore(artifactRoot: liveRoot)
    existingArtifacts = try existingFiles.keys.map {
      try PrivateHeaderGeneration.ArtifactPath($0)
    }
    incomingArtifacts = try incomingFiles.keys.map {
      try PrivateHeaderGeneration.ArtifactPath($0)
    }
    self.artifactRoot = try PrivateHeaderGeneration.ArtifactPath(artifactRoot)
    for (path, contents) in existingFiles {
      try write(contents, to: liveURL(path))
    }
    for (path, contents) in incomingFiles {
      let relativePath = try #require(path.removingPrefix("\(artifactRoot)/"))
      try write(contents, to: stagingRoot.appendingPathComponent("output/\(relativePath)"))
    }
  }

  func prepareReplacement(
    removing: [PrivateHeaderGeneration.ArtifactPath]? = nil,
    fileManager: FileManager = .default,
    exclusiveRename: (URL, URL) throws -> Void = ManagedFileSystem.atomicRenameExclusively
  ) throws -> PrivateHeaderGeneration.ArtifactStore.Replacement {
    return try store.prepareReplacement(
      stagingDirectory: stagingRoot,
      stagedSourceDirectory: stagingRoot.appendingPathComponent("output", isDirectory: true),
      artifactRoot: artifactRoot,
      artifacts: incomingArtifacts,
      removing: removing ?? existingArtifacts,
      runID: .init(rawValue: "run-replacement"),
      targetID: "framework:Foo.framework",
      at: transactionDirectory,
      fileManager: fileManager,
      exclusiveRename: exclusiveRename
    )
  }

  func backupURL(_ relativePath: String) -> URL {
    transactionDirectory
      .appendingPathComponent("backup", isDirectory: true)
      .appendingPathComponent(relativePath)
  }

  func rewriteManifest(_ mutation: (inout [String: Any]) -> Void) throws {
    let manifestURL = transactionDirectory.appendingPathComponent("manifest.json")
    var manifest = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
        as? [String: Any]
    )
    mutation(&manifest)
    try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
      .write(to: manifestURL, options: .atomic)
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

private final class FailingOnceDirectoryCreationFileManager: FileManager, @unchecked Sendable {
  private let failingPath: String
  private var hasFailed = false

  init(failingPath: String) {
    self.failingPath = failingPath
    super.init()
  }

  override func createDirectory(
    at url: URL,
    withIntermediateDirectories createIntermediates: Bool,
    attributes: [FileAttributeKey: Any]? = nil
  ) throws {
    if url.path == failingPath, !hasFailed {
      hasFailed = true
      throw InjectedReplacementFailure.stop
    }
    try super.createDirectory(
      at: url,
      withIntermediateDirectories: createIntermediates,
      attributes: attributes
    )
  }
}

private final class FailingOnceRestoreCopyFileManager: FileManager, @unchecked Sendable {
  private var hasFailed = false

  override func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
    if destinationURL.path.contains("/restore/"), !hasFailed {
      hasFailed = true
      try super.createDirectory(
        at: destinationURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try "partial".write(to: destinationURL, atomically: true, encoding: .utf8)
      throw InjectedReplacementFailure.stop
    }
    try super.copyItem(at: sourceURL, to: destinationURL)
  }
}

private final class DifferentTransactionDeviceFileManager: FileManager, @unchecked Sendable {
  override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
    var attributes = try super.attributesOfItem(atPath: path)
    if path.contains("/incoming") || path.contains("/restore") {
      let current = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
      attributes[.systemNumber] = NSNumber(value: current &+ 1)
    }
    return attributes
  }
}

private extension String {
  func removingPrefix(_ prefix: String) -> String? {
    guard hasPrefix(prefix) else { return nil }
    return String(dropFirst(prefix.count))
  }
}

private extension Array {
  var only: Element? {
    count == 1 ? self[0] : nil
  }
}
