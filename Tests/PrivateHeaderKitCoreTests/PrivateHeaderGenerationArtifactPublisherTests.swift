import Foundation
import Testing

@testable import PrivateHeaderKitCore

@Suite
struct PrivateHeaderGenerationArtifactPublisherTests {
  @Test func publishesImmutableGenerationThroughStableAndCurrentPointers() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    let generationID = PrivateHeaderGeneration.GenerationID(rawValue: "generation-one")
    let prepared = try fixture.prepare(
      generationID: generationID,
      targetID: "framework:Foo",
      relativePath: "Frameworks/Foo/Foo.h",
      contents: "new"
    )

    #expect(try fixture.publisher.inspect().currentGenerationID == nil)
    try fixture.publisher.movePreparedGeneration(prepared)
    try fixture.publisher.switchCurrent(to: generationID)
    try fixture.publisher.ensureStablePointer()

    let snapshot = try fixture.publisher.inspect()
    #expect(snapshot.currentGenerationID == generationID)
    #expect(snapshot.stablePathState == .managed)
    #expect(
      snapshot.currentMarker?.artifactsByTarget["framework:Foo"]?.map(\.rawValue) == [
        "Frameworks/Foo/Foo.h"
      ])
    #expect(
      try String(
        contentsOf: fixture.publisher.stableURL.appendingPathComponent("Frameworks/Foo/Foo.h"),
        encoding: .utf8) == "new")
  }

  @Test func legacyFreshMigrationPreservesOpaqueContentAndRetainsOriginalTree() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    let unknown = fixture.publisher.stableURL.appendingPathComponent("Notes/custom.txt")
    try FileManager.default.createDirectory(
      at: unknown.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("opaque".utf8).write(to: unknown)
    let generationID = PrivateHeaderGeneration.GenerationID(rawValue: "generation-legacy")
    let prepared = try fixture.prepare(
      generationID: generationID,
      targetID: "framework:Foo",
      relativePath: "Frameworks/Foo/Foo.h",
      contents: "header",
      allowLegacyMigration: true
    )
    try fixture.publisher.movePreparedGeneration(prepared)
    try fixture.publisher.switchCurrent(to: generationID)
    try fixture.publisher.ensureStablePointer()

    #expect(try fixture.publisher.inspect().stablePathState == .managed)
    #expect(
      try String(
        contentsOf: fixture.publisher.stableURL.appendingPathComponent("Notes/custom.txt"),
        encoding: .utf8) == "opaque")
    let backups = try FileManager.default.contentsOfDirectory(
      at: fixture.publisher.managedRoot.appendingPathComponent("legacy-backups"),
      includingPropertiesForKeys: nil
    )
    #expect(backups.count == 1)
    #expect(
      try String(contentsOf: backups[0].appendingPathComponent("Notes/custom.txt"), encoding: .utf8)
        == "opaque")
  }

  @Test func unsuccessfulDraftNeverChangesCurrentGeneration() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    let oldID = PrivateHeaderGeneration.GenerationID(rawValue: "generation-old")
    try fixture.publish(
      fixture.prepare(
        generationID: oldID,
        targetID: "framework:Foo",
        relativePath: "Frameworks/Foo/Foo.h",
        contents: "old"
      )
    )
    let draft = try fixture.publisher.beginDraft(
      generationID: .init(rawValue: "generation-failed"),
      allowLegacyMigration: false
    )
    try fixture.publisher.discardDraft(draft)

    #expect(try fixture.publisher.inspect().currentGenerationID == oldID)
    #expect(
      try String(
        contentsOf: fixture.publisher.stableURL.appendingPathComponent("Frameworks/Foo/Foo.h"),
        encoding: .utf8) == "old")
  }

  @Test func replacingOneOwnerPreservesOpaqueAndOtherTargetFiles() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    let legacyUnknown = fixture.publisher.stableURL.appendingPathComponent("User/keep.txt")
    try FileManager.default.createDirectory(
      at: legacyUnknown.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: legacyUnknown)
    let first = try fixture.prepare(
      generationID: .init(rawValue: "generation-first"),
      targetID: "framework:Foo",
      relativePath: "Frameworks/Foo/Old.h",
      contents: "old",
      allowLegacyMigration: true
    )
    try fixture.publish(first)

    var draft = try fixture.publisher.beginDraft(
      generationID: .init(rawValue: "generation-second"),
      allowLegacyMigration: false
    )
    let barSource = try fixture.sourceFile(contents: "bar")
    draft = try fixture.publisher.applyCompletedTarget(
      targetID: "framework:Bar",
      files: [.init(rawValue: "Frameworks/Bar/Bar.h"): barSource],
      to: draft
    )
    let fooSource = try fixture.sourceFile(contents: "new")
    draft = try fixture.publisher.applyCompletedTarget(
      targetID: "framework:Foo",
      files: [.init(rawValue: "Frameworks/Foo/New.h"): fooSource],
      to: draft
    )
    try fixture.publish(
      try fixture.publisher.prepareGeneration(draft, planFingerprint: "fingerprint"))

    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.publisher.stableURL.appendingPathComponent("Frameworks/Foo/Old.h").path))
    #expect(
      try String(
        contentsOf: fixture.publisher.stableURL.appendingPathComponent("Frameworks/Bar/Bar.h"),
        encoding: .utf8) == "bar")
    #expect(
      try String(
        contentsOf: fixture.publisher.stableURL.appendingPathComponent("User/keep.txt"),
        encoding: .utf8) == "keep")
  }

  @Test func replacingTheTargetSetDropsAbsentDraftOwners() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    try fixture.publish(
      fixture.prepare(
        generationID: .init(rawValue: "generation-foo"),
        targetID: "framework:Foo",
        relativePath: "Frameworks/Foo/Foo.h",
        contents: "foo"
      )
    )
    var combinedDraft = try fixture.publisher.beginDraft(
      generationID: .init(rawValue: "generation-combined"),
      allowLegacyMigration: false
    )
    combinedDraft = try fixture.publisher.applyCompletedTarget(
      targetID: "framework:Bar",
      files: [
        .init(rawValue: "Frameworks/Bar/Bar.h"): try fixture.sourceFile(contents: "bar")
      ],
      to: combinedDraft
    )
    try fixture.publish(
      try fixture.publisher.prepareGeneration(
        combinedDraft,
        planFingerprint: "fingerprint"
      )
    )

    let seededDraft = try fixture.publisher.beginDraft(
      generationID: .init(rawValue: "generation-exact"),
      allowLegacyMigration: false
    )
    let exactDraft = try fixture.publisher.replaceCompletedTargets(
      [
        "framework:Bar": [
          .init(rawValue: "Frameworks/Bar/Bar.h"): try fixture.sourceFile(
            contents: "bar-new"
          )
        ]
      ],
      in: seededDraft
    )
    let prepared = try fixture.publisher.prepareGeneration(
      exactDraft,
      planFingerprint: "fingerprint"
    )

    #expect(prepared.marker.artifactsByTarget.keys.sorted() == ["framework:Bar"])
    #expect(!FileManager.default.fileExists(
      atPath: prepared.draftDirectory.appendingPathComponent("Frameworks/Foo/Foo.h").path
    ))
  }

  @Test func replacingTheTargetSetWithEmptySetDropsEveryDraftOwner() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    let legacyUnknown = fixture.publisher.stableURL.appendingPathComponent("User/keep.txt")
    try FileManager.default.createDirectory(
      at: legacyUnknown.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("keep".utf8).write(to: legacyUnknown)
    try fixture.publish(
      fixture.prepare(
        generationID: .init(rawValue: "generation-foo"),
        targetID: "framework:Foo",
        relativePath: "Frameworks/Foo/Foo.h",
        contents: "foo",
        allowLegacyMigration: true
      )
    )

    let seededDraft = try fixture.publisher.beginDraft(
      generationID: .init(rawValue: "generation-empty"),
      allowLegacyMigration: false
    )
    let exactDraft = try fixture.publisher.replaceCompletedTargets([:], in: seededDraft)
    let prepared = try fixture.publisher.prepareGeneration(
      exactDraft,
      planFingerprint: "fingerprint"
    )

    #expect(prepared.marker.artifactsByTarget.isEmpty)
    #expect(!FileManager.default.fileExists(
      atPath: prepared.draftDirectory.appendingPathComponent("Frameworks/Foo/Foo.h").path
    ))
    #expect(try String(
      contentsOf: prepared.draftDirectory.appendingPathComponent("User/keep.txt"),
      encoding: .utf8
    ) == "keep")
  }

  @Test func rawStagingRejectsHiddenUnsupportedAndSymlinkPayloads() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    let staging = fixture.root.appendingPathComponent("raw-staging")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
    let header = staging.appendingPathComponent("Foo.h")
    try Data("header".utf8).write(to: header)
    try Data("hidden".utf8).write(to: staging.appendingPathComponent(".payload"))
    #expect(throws: ArtifactPublisher.PublisherError.self) {
      try fixture.publisher.validateRawStaging(root: staging, expectedSourceFiles: [header])
    }

    try FileManager.default.removeItem(at: staging.appendingPathComponent(".payload"))
    try Data("bad".utf8).write(to: staging.appendingPathComponent("payload.txt"))
    #expect(throws: ArtifactPublisher.PublisherError.self) {
      try fixture.publisher.validateRawStaging(root: staging, expectedSourceFiles: [header])
    }

    try FileManager.default.removeItem(at: staging.appendingPathComponent("payload.txt"))
    try FileManager.default.createSymbolicLink(
      at: staging.appendingPathComponent("Alias.h"),
      withDestinationURL: header
    )
    #expect(throws: ArtifactPublisher.PublisherError.self) {
      try fixture.publisher.validateRawStaging(root: staging, expectedSourceFiles: [header])
    }
  }

  @Test func managedDirectoryChainRejectsPreexistingSymlink() throws {
    let root = try publisherTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = try publisherTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent(".privateheaderkit"),
      withDestinationURL: outside
    )
    let publisher = try ArtifactPublisher(artifactBaseDirectory: root, sourceLabel: "iOS27")
    #expect(throws: ArtifactPublisher.PublisherError.self) {
      try publisher.prepareForLease()
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
  }

  @Test func outputSymlinkAliasesShareCanonicalLeaseIdentity() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    let alias = fixture.root.deletingLastPathComponent().appendingPathComponent(
      "alias-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: alias) }
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
    let throughAlias = try ArtifactPublisher(artifactBaseDirectory: alias, sourceLabel: "iOS27")
    #expect(throughAlias.artifactBaseDirectory == fixture.publisher.artifactBaseDirectory)
    #expect(throughAlias.lockURL == fixture.publisher.lockURL)
  }

  @Test func reservedLegacyMarkerAndMalformedManagedGenerationFailFast() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    try FileManager.default.createDirectory(
      at: fixture.publisher.stableURL, withIntermediateDirectories: true)
    try Data("user".utf8).write(
      to: fixture.publisher.stableURL.appendingPathComponent(".privateheaderkit-generation.json")
    )
    #expect(throws: ArtifactPublisher.PublisherError.self) {
      _ = try fixture.publisher.beginDraft(
        generationID: .init(rawValue: "generation-reserved"),
        allowLegacyMigration: true
      )
    }
  }

  @Test func markerRejectsArtifactOwnedByMultipleTargets() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    let generationID = PrivateHeaderGeneration.GenerationID(rawValue: "generation-duplicate-owner")
    let prepared = try fixture.prepare(
      generationID: generationID,
      targetID: "framework:Foo",
      relativePath: "Frameworks/Foo/Foo.h",
      contents: "header"
    )
    try fixture.publisher.movePreparedGeneration(prepared)
    let markerURL = prepared.finalDirectory.appendingPathComponent(
      ".privateheaderkit-generation.json"
    )
    let data = try Data(contentsOf: markerURL)
    var marker = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var ownership = try #require(marker["artifactsByTarget"] as? [String: Any])
    ownership["framework:Bar"] = ["Frameworks/Foo/Foo.h"]
    marker["artifactsByTarget"] = ownership
    try JSONSerialization.data(withJSONObject: marker).write(to: markerURL)

    #expect(throws: ArtifactPublisher.PublisherError.self) {
      _ = try fixture.publisher.inspect()
    }
  }

  @Test func applyRejectsCaseAliasedPathsWithinOneTargetBeforeMutation() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    let draft = try fixture.publisher.beginDraft(
      generationID: .init(rawValue: "generation-case-alias"),
      allowLegacyMigration: false
    )
    let upperSource = try fixture.sourceFile(contents: "upper")
    let lowerSource = try fixture.sourceFile(contents: "lower")

    #expect(
      throws: ArtifactPublisher.PublisherError.artifactCollision(
        firstPath: "Frameworks/Foo/Headers/A.h",
        firstOwner: "framework:Foo",
        secondPath: "Frameworks/Foo/Headers/a.h",
        secondOwner: "framework:Foo"
      )
    ) {
      _ = try fixture.publisher.applyCompletedTarget(
        targetID: "framework:Foo",
        files: [
          .init(rawValue: "Frameworks/Foo/Headers/A.h"): upperSource,
          .init(rawValue: "Frameworks/Foo/Headers/a.h"): lowerSource,
        ],
        to: draft
      )
    }

    #expect(try FileManager.default.contentsOfDirectory(atPath: draft.directory.path).isEmpty)
  }

  @Test func applyRejectsCanonicalUnicodeAliasInSharedComponents() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    var draft = try fixture.publisher.beginDraft(
      generationID: .init(rawValue: "generation-unicode-alias"),
      allowLegacyMigration: false
    )
    let decomposedPath = "Frameworks/Cafe\u{301}/Headers/A.h"
    let composedPath = "Frameworks/Caf\u{e9}/Headers/B.h"
    draft = try fixture.publisher.applyCompletedTarget(
      targetID: "framework:A",
      files: [.init(rawValue: decomposedPath): try fixture.sourceFile(contents: "first")],
      to: draft
    )

    #expect(throws: ArtifactPublisher.PublisherError.self) {
      _ = try fixture.publisher.applyCompletedTarget(
        targetID: "framework:B",
        files: [.init(rawValue: composedPath): try fixture.sourceFile(contents: "second")],
        to: draft
      )
    }
    #expect(
      try String(
        contentsOf: draft.directory.appendingPathComponent(decomposedPath),
        encoding: .utf8
      ) == "first"
    )
    #expect(
      !FileManager.default.fileExists(
        atPath: draft.directory.appendingPathComponent(composedPath).path
      ))
  }

  @Test func applyRejectsLeafParentCollisionBeforeMutation() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    let draft = try fixture.publisher.beginDraft(
      generationID: .init(rawValue: "generation-prefix"),
      allowLegacyMigration: false
    )

    #expect(throws: ArtifactPublisher.PublisherError.self) {
      _ = try fixture.publisher.applyCompletedTarget(
        targetID: "framework:Foo",
        files: [
          .init(rawValue: "Frameworks/Foo/Headers"): try fixture.sourceFile(contents: "leaf"),
          .init(rawValue: "Frameworks/Foo/Headers/Foo.h"):
            try fixture.sourceFile(contents: "child"),
        ],
        to: draft
      )
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: draft.directory.path).isEmpty)
  }

  @Test func applyRejectsPortableAliasOfOpaquePathButAllowsExactClaim() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    let opaquePath = "Frameworks/Foo/Headers/User.h"
    let opaqueURL = fixture.publisher.stableURL.appendingPathComponent(opaquePath)
    try FileManager.default.createDirectory(
      at: opaqueURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("opaque".utf8).write(to: opaqueURL)
    let draft = try fixture.publisher.beginDraft(
      generationID: .init(rawValue: "generation-opaque-alias"),
      allowLegacyMigration: true
    )

    #expect(throws: ArtifactPublisher.PublisherError.self) {
      _ = try fixture.publisher.applyCompletedTarget(
        targetID: "framework:Foo",
        files: [
          .init(rawValue: "Frameworks/Foo/Headers/user.h"):
            try fixture.sourceFile(contents: "generated")
        ],
        to: draft
      )
    }
    #expect(
      try String(
        contentsOf: draft.directory.appendingPathComponent(opaquePath),
        encoding: .utf8
      ) == "opaque"
    )

    let claimed = try fixture.publisher.applyCompletedTarget(
      targetID: "framework:Foo",
      files: [
        .init(rawValue: opaquePath): try fixture.sourceFile(contents: "generated")
      ],
      to: draft
    )
    #expect(claimed.opaquePaths.isEmpty)
    #expect(claimed.artifactsByTarget["framework:Foo"] == [.init(rawValue: opaquePath)])
    #expect(
      try String(
        contentsOf: claimed.directory.appendingPathComponent(opaquePath),
        encoding: .utf8
      ) == "generated"
    )
  }

  @Test func opaqueClaimsUseExactUTF8PathIdentity() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    let composed = PrivateHeaderGeneration.ArtifactPath(
      rawValue: "Frameworks/F\u{00E9}/Headers/Generated.h"
    )
    let decomposed = PrivateHeaderGeneration.ArtifactPath(
      rawValue: "Frameworks/Fe\u{301}/Headers/Generated.h"
    )
    let unrelated = PrivateHeaderGeneration.ArtifactPath(
      rawValue: "Frameworks/Bar/Headers/Generated.h"
    )

    #expect(
      ArtifactPublisher.unclaimedOpaquePaths([decomposed], claimedBy: [composed])
        == [decomposed]
    )
    #expect(
      ArtifactPublisher.unclaimedOpaquePaths([decomposed], claimedBy: [decomposed]).isEmpty
    )
    #expect(throws: ArtifactPublisher.PublisherError.self) {
      _ = try fixture.publisher.validateTargetReplacement(
        targetID: "framework:Bar",
        artifacts: [unrelated],
        existingArtifactsByTarget: ["framework:Foo": [composed]],
        opaquePaths: [decomposed]
      )
    }
  }

  @Test func applyAllowsIdenticalSharedDirectoryComponents() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    var draft = try fixture.publisher.beginDraft(
      generationID: .init(rawValue: "generation-shared-directory"),
      allowLegacyMigration: false
    )
    draft = try fixture.publisher.applyCompletedTarget(
      targetID: "framework:A",
      files: [
        .init(rawValue: "Frameworks/Shared/Headers/A.h"):
          try fixture.sourceFile(contents: "a")
      ],
      to: draft
    )
    draft = try fixture.publisher.applyCompletedTarget(
      targetID: "framework:B",
      files: [
        .init(rawValue: "Frameworks/Shared/Headers/B.h"):
          try fixture.sourceFile(contents: "b")
      ],
      to: draft
    )

    let prepared = try fixture.publisher.prepareGeneration(draft, planFingerprint: "fingerprint")
    #expect(prepared.marker.artifactsByTarget.keys.sorted() == ["framework:A", "framework:B"])
  }

  @Test func prospectiveNamespaceModelsShapeAndSpellingChangesWithoutFilesystemSemantics() throws {
    let root = URL(fileURLWithPath: "/draft", isDirectory: true)
    let oldFile = PrivateHeaderGeneration.ArtifactPath(rawValue: "Artifacts/A")
    let fileToDirectory = try ArtifactPublisher.ProspectiveNamespace(
      ownedPaths: [oldFile],
      existingDirectories: [],
      existingRegularPaths: [oldFile],
      pathsToRemove: [oldFile]
    )
    try fileToDirectory.preflightDestination(
      .init(rawValue: "Artifacts/A/Header.h"),
      destination: root.appendingPathComponent("Artifacts/A/Header.h")
    )

    let oldChild = PrivateHeaderGeneration.ArtifactPath(rawValue: "Artifacts/A/Header.h")
    let directoryToFile = try ArtifactPublisher.ProspectiveNamespace(
      ownedPaths: [oldChild],
      existingDirectories: [.init(rawValue: "Artifacts"), .init(rawValue: "Artifacts/A")],
      existingRegularPaths: [oldChild],
      pathsToRemove: [oldChild]
    )
    try directoryToFile.preflightDestination(
      .init(rawValue: "Artifacts/A"),
      destination: root.appendingPathComponent("Artifacts/A")
    )

    let uppercase = PrivateHeaderGeneration.ArtifactPath(rawValue: "Headers/Name.h")
    let caseRename = try ArtifactPublisher.ProspectiveNamespace(
      ownedPaths: [uppercase],
      existingDirectories: [.init(rawValue: "Headers")],
      existingRegularPaths: [uppercase],
      pathsToRemove: [uppercase]
    )
    try caseRename.preflightDestination(
      .init(rawValue: "Headers/name.h"),
      destination: root.appendingPathComponent("Headers/name.h")
    )

    let decomposed = PrivateHeaderGeneration.ArtifactPath(
      rawValue: "Headers/Cafe\u{301}.h"
    )
    let normalizationRename = try ArtifactPublisher.ProspectiveNamespace(
      ownedPaths: [decomposed],
      existingDirectories: [.init(rawValue: "Headers")],
      existingRegularPaths: [decomposed],
      pathsToRemove: [decomposed]
    )
    try normalizationRename.preflightDestination(
      .init(rawValue: "Headers/Caf\u{e9}.h"),
      destination: root.appendingPathComponent("Headers/Caf\u{e9}.h")
    )
  }

  @Test func prospectiveNamespaceRejectsNormalizationAliasOfActualOnlyDirectory() throws {
    let decomposedDirectory = PrivateHeaderGeneration.ArtifactPath(
      rawValue: "Directories/Cafe\u{301}"
    )
    let namespace = try ArtifactPublisher.ProspectiveNamespace(
      ownedPaths: [],
      existingDirectories: [
        .init(rawValue: "Directories"),
        decomposedDirectory,
      ],
      existingRegularPaths: [],
      pathsToRemove: []
    )

    #expect(throws: ArtifactPublisher.PublisherError.self) {
      try namespace.preflightDestination(
        .init(rawValue: "Directories/Caf\u{e9}/Header.h"),
        destination: URL(fileURLWithPath: "/draft/Directories/Caf\u{e9}/Header.h")
      )
    }
  }

  @Test func prospectiveNamespaceRejectsTwoObservedNormalizationAliases() {
    #expect(throws: ArtifactPublisher.PublisherError.self) {
      _ = try ArtifactPublisher.ProspectiveNamespace(
        ownedPaths: [],
        existingDirectories: [
          .init(rawValue: "Directories/Cafe\u{301}"),
          .init(rawValue: "Directories/Caf\u{e9}"),
        ],
        existingRegularPaths: [],
        pathsToRemove: []
      )
    }
  }

  @Test func applySupportsFileToDirectoryTransition() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    try fixture.publish(
      fixture.prepare(
        generationID: .init(rawValue: "generation-file-to-directory-old"),
        targetID: "framework:Foo",
        relativePath: "Artifacts/A",
        contents: "old"
      )
    )
    var draft = try fixture.publisher.beginDraft(
      generationID: .init(rawValue: "generation-file-to-directory-new"),
      allowLegacyMigration: false
    )

    draft = try fixture.publisher.applyCompletedTarget(
      targetID: "framework:Foo",
      files: [
        .init(rawValue: "Artifacts/A/Header.h"): try fixture.sourceFile(contents: "new")
      ],
      to: draft
    )

    #expect(
      try String(
        contentsOf: draft.directory.appendingPathComponent("Artifacts/A/Header.h"),
        encoding: .utf8
      ) == "new"
    )
    _ = try fixture.publisher.prepareGeneration(draft, planFingerprint: "fingerprint")
  }

  @Test func prospectiveTransitionFailureLeavesOldNamespaceUntouched() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    try fixture.publish(
      fixture.prepare(
        generationID: .init(rawValue: "generation-transition-failure-old"),
        targetID: "framework:Foo",
        relativePath: "Artifacts/A",
        contents: "old"
      )
    )
    let draft = try fixture.publisher.beginDraft(
      generationID: .init(rawValue: "generation-transition-failure-new"),
      allowLegacyMigration: false
    )
    let outside = try fixture.sourceFile(contents: "outside")
    let unsafeDestination = draft.directory.appendingPathComponent("Artifacts/Z.h")
    try FileManager.default.createSymbolicLink(
      at: unsafeDestination,
      withDestinationURL: outside
    )

    do {
      _ = try fixture.publisher.applyCompletedTarget(
        targetID: "framework:Foo",
        files: [
          .init(rawValue: "Artifacts/A/Header.h"): try fixture.sourceFile(contents: "new"),
          .init(rawValue: "Artifacts/Z.h"): try fixture.sourceFile(contents: "z"),
        ],
        to: draft
      )
      Issue.record("expected destination preflight to fail")
    } catch let error as ArtifactPublisher.PublisherError {
      if case .unexpectedItem(let path, let description) = error {
        #expect(path.hasSuffix("/Artifacts/Z.h"))
        #expect(description == "symbolic links are not allowed")
      } else {
        Issue.record("unexpected publisher error: \(error)")
      }
    } catch {
      Issue.record("unexpected error: \(error)")
    }
    #expect(
      try String(
        contentsOf: draft.directory.appendingPathComponent("Artifacts/A"),
        encoding: .utf8
      ) == "old"
    )
    #expect(try String(contentsOf: outside, encoding: .utf8) == "outside")
  }

  @Test func applyPreflightsEverySourceBeforeRemovingReplacedArtifacts() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    try fixture.publish(
      fixture.prepare(
        generationID: .init(rawValue: "generation-source-preflight-old"),
        targetID: "framework:Foo",
        relativePath: "Frameworks/Foo/Headers/Old.h",
        contents: "old"
      )
    )
    let draft = try fixture.publisher.beginDraft(
      generationID: .init(rawValue: "generation-source-preflight-new"),
      allowLegacyMigration: false
    )
    let invalidSource = fixture.root.appendingPathComponent("invalid-source", isDirectory: true)
    try FileManager.default.createDirectory(at: invalidSource, withIntermediateDirectories: false)

    #expect(throws: ArtifactPublisher.PublisherError.self) {
      _ = try fixture.publisher.applyCompletedTarget(
        targetID: "framework:Foo",
        files: [
          .init(rawValue: "Frameworks/Foo/Headers/A.h"):
            try fixture.sourceFile(contents: "a"),
          .init(rawValue: "Frameworks/Foo/Headers/Z.h"): invalidSource,
        ],
        to: draft
      )
    }
    #expect(
      try String(
        contentsOf: draft.directory.appendingPathComponent("Frameworks/Foo/Headers/Old.h"),
        encoding: .utf8
      ) == "old"
    )
    #expect(
      !FileManager.default.fileExists(
        atPath: draft.directory.appendingPathComponent("Frameworks/Foo/Headers/A.h").path
      ))
  }

  @Test func applyPreflightsEveryDestinationBeforeRemovingReplacedArtifacts() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    try fixture.publish(
      fixture.prepare(
        generationID: .init(rawValue: "generation-destination-preflight-old"),
        targetID: "framework:Foo",
        relativePath: "Frameworks/Foo/Headers/Old.h",
        contents: "old"
      )
    )
    let draft = try fixture.publisher.beginDraft(
      generationID: .init(rawValue: "generation-destination-preflight-new"),
      allowLegacyMigration: false
    )
    let outside = try fixture.sourceFile(contents: "outside")
    let unsafeDestination = draft.directory.appendingPathComponent(
      "Frameworks/Foo/Headers/Z.h"
    )
    try FileManager.default.createSymbolicLink(
      at: unsafeDestination,
      withDestinationURL: outside
    )

    #expect(throws: ArtifactPublisher.PublisherError.self) {
      _ = try fixture.publisher.applyCompletedTarget(
        targetID: "framework:Foo",
        files: [
          .init(rawValue: "Frameworks/Foo/Headers/A.h"):
            try fixture.sourceFile(contents: "a"),
          .init(rawValue: "Frameworks/Foo/Headers/Z.h"):
            try fixture.sourceFile(contents: "z"),
        ],
        to: draft
      )
    }
    #expect(
      try String(
        contentsOf: draft.directory.appendingPathComponent("Frameworks/Foo/Headers/Old.h"),
        encoding: .utf8
      ) == "old"
    )
    #expect(try String(contentsOf: outside, encoding: .utf8) == "outside")
    #expect(
      !FileManager.default.fileExists(
        atPath: draft.directory.appendingPathComponent("Frameworks/Foo/Headers/A.h").path
      ))
  }

  @Test func applyPreflightsEveryRemovalBeforeDeletingAnyOwnedArtifact() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    var initialDraft = try fixture.publisher.beginDraft(
      generationID: .init(rawValue: "generation-removal-preflight-old"),
      allowLegacyMigration: false
    )
    initialDraft = try fixture.publisher.applyCompletedTarget(
      targetID: "framework:Foo",
      files: [
        .init(rawValue: "Frameworks/Foo/Headers/A.h"):
          try fixture.sourceFile(contents: "a"),
        .init(rawValue: "Frameworks/Foo/Headers/Z.h"):
          try fixture.sourceFile(contents: "z"),
      ],
      to: initialDraft
    )
    try fixture.publish(
      fixture.publisher.prepareGeneration(initialDraft, planFingerprint: "fingerprint")
    )
    let draft = try fixture.publisher.beginDraft(
      generationID: .init(rawValue: "generation-removal-preflight-new"),
      allowLegacyMigration: false
    )
    let invalidRemoval = draft.directory.appendingPathComponent("Frameworks/Foo/Headers/Z.h")
    try FileManager.default.removeItem(at: invalidRemoval)
    try FileManager.default.createDirectory(at: invalidRemoval, withIntermediateDirectories: false)

    #expect(throws: ArtifactPublisher.PublisherError.self) {
      _ = try fixture.publisher.applyCompletedTarget(
        targetID: "framework:Foo",
        files: [
          .init(rawValue: "Frameworks/Foo/Headers/New.h"):
            try fixture.sourceFile(contents: "new")
        ],
        to: draft
      )
    }
    #expect(
      try String(
        contentsOf: draft.directory.appendingPathComponent("Frameworks/Foo/Headers/A.h"),
        encoding: .utf8
      ) == "a"
    )
    #expect(
      !FileManager.default.fileExists(
        atPath: draft.directory.appendingPathComponent("Frameworks/Foo/Headers/New.h").path
      ))
  }

  @Test func prepareGenerationRejectsForgedDraftCollisionBeforeInventoryMismatch() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    let baseDraft = try fixture.publisher.beginDraft(
      generationID: .init(rawValue: "generation-forged-draft"),
      allowLegacyMigration: false
    )
    let forged = ArtifactPublisher.Draft(
      generationID: baseDraft.generationID,
      directory: baseDraft.directory,
      artifactsByTarget: [
        "framework:Foo": [
          .init(rawValue: "Frameworks/Foo/Headers/A.h"),
          .init(rawValue: "Frameworks/Foo/Headers/a.h"),
        ]
      ],
      opaquePaths: []
    )

    #expect(
      throws: ArtifactPublisher.PublisherError.artifactCollision(
        firstPath: "Frameworks/Foo/Headers/A.h",
        firstOwner: "framework:Foo",
        secondPath: "Frameworks/Foo/Headers/a.h",
        secondOwner: "framework:Foo"
      )
    ) {
      _ = try fixture.publisher.prepareGeneration(forged, planFingerprint: "fingerprint")
    }
  }

  @Test func inspectPrioritizesPersistedPortableCollisionOverChecksumAndInventory() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    let prepared = try fixture.prepare(
      generationID: .init(rawValue: "generation-persisted-collision"),
      targetID: "framework:Foo",
      relativePath: "Frameworks/Foo/Headers/Foo.h",
      contents: "header"
    )
    try fixture.publisher.movePreparedGeneration(prepared)
    let markerURL = prepared.finalDirectory.appendingPathComponent(
      ".privateheaderkit-generation.json"
    )
    var marker = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any]
    )
    var ownership = try #require(marker["artifactsByTarget"] as? [String: Any])
    ownership["framework:Bar"] = ["Frameworks/Foo/Headers/foo.h"]
    marker["artifactsByTarget"] = ownership
    marker["artifactChecksum"] = "intentionally-invalid"
    try JSONSerialization.data(withJSONObject: marker).write(to: markerURL)

    #expect(
      throws: ArtifactPublisher.PublisherError.artifactCollision(
        firstPath: "Frameworks/Foo/Headers/Foo.h",
        firstOwner: "framework:Foo",
        secondPath: "Frameworks/Foo/Headers/foo.h",
        secondOwner: "framework:Bar"
      )
    ) {
      _ = try fixture.publisher.inspect()
    }
  }

  @Test func stableReaderObservesOnlyCompleteOldOrNewGenerations() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    let oldID = PrivateHeaderGeneration.GenerationID(rawValue: "generation-old")
    try fixture.publish(
      try fixture.prepare(
        generationID: oldID,
        targetID: "framework:Foo",
        relativePath: "Frameworks/Foo/Foo.h",
        contents: "old"
      ))
    #expect(
      try String(
        contentsOf: fixture.publisher.stableURL.appendingPathComponent("Frameworks/Foo/Foo.h"),
        encoding: .utf8) == "old")

    let newID = PrivateHeaderGeneration.GenerationID(rawValue: "generation-new")
    let prepared = try fixture.prepare(
      generationID: newID,
      targetID: "framework:Foo",
      relativePath: "Frameworks/Foo/Foo.h",
      contents: "new"
    )
    try fixture.publisher.movePreparedGeneration(prepared)
    #expect(
      try String(
        contentsOf: fixture.publisher.stableURL.appendingPathComponent("Frameworks/Foo/Foo.h"),
        encoding: .utf8) == "old")
    try fixture.publisher.switchCurrent(to: newID)
    #expect(
      try String(
        contentsOf: fixture.publisher.stableURL.appendingPathComponent("Frameworks/Foo/Foo.h"),
        encoding: .utf8) == "new")
  }

  @Test func prepareGenerationRemovesFinderMetadataFromManagedSnapshots() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    var draft = try fixture.publisher.beginDraft(
      generationID: .init(rawValue: "generation-finder-metadata"),
      allowLegacyMigration: false
    )
    draft = try fixture.publisher.applyCompletedTarget(
      targetID: "framework:Foo",
      files: [
        .init(rawValue: "Frameworks/Foo/Foo.h"): try fixture.sourceFile(contents: "header")
      ],
      to: draft
    )
    let rootMetadata = draft.directory.appendingPathComponent(".DS_Store")
    let nestedMetadata = draft.directory.appendingPathComponent("Frameworks/Foo/.DS_Store")
    try Data("finder".utf8).write(to: rootMetadata)
    try Data("finder".utf8).write(to: nestedMetadata)

    let prepared = try fixture.publisher.prepareGeneration(
      draft,
      planFingerprint: "fingerprint"
    )

    #expect(!FileManager.default.fileExists(atPath: rootMetadata.path))
    #expect(!FileManager.default.fileExists(atPath: nestedMetadata.path))
    #expect(
      prepared.marker.artifactsByTarget["framework:Foo"] == [
        .init(rawValue: "Frameworks/Foo/Foo.h")
      ])
  }

  @Test func inspectRejectsGenerationWhoseArtifactContentsChanged() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    try fixture.publish(
      try fixture.prepare(
        generationID: .init(rawValue: "generation-content-authentication"),
        targetID: "framework:Foo",
        relativePath: "Frameworks/Foo/Foo.h",
        contents: "original"
      )
    )
    try Data("tampered".utf8).write(
      to: fixture.publisher.stableURL.appendingPathComponent("Frameworks/Foo/Foo.h")
    )

    #expect(throws: ArtifactPublisher.PublisherError.self) {
      _ = try fixture.publisher.inspect()
    }
  }

  @Test func prepareGenerationRejectsUnexpectedPublishedTargetBytes() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    var draft = try fixture.publisher.beginDraft(
      generationID: .init(rawValue: "generation-expected-digest"),
      allowLegacyMigration: false
    )
    let path = PrivateHeaderGeneration.ArtifactPath(rawValue: "Frameworks/Foo/Foo.h")
    draft = try fixture.publisher.applyCompletedTarget(
      targetID: "framework:Foo",
      files: [path: try fixture.sourceFile(contents: "actual")],
      to: draft
    )

    #expect(throws: ArtifactPublisher.PublisherError.self) {
      _ = try fixture.publisher.prepareGeneration(
        draft,
        planFingerprint: "fingerprint",
        expectedArtifactDigestsByTarget: [
          "framework:Foo": [path: String(repeating: "0", count: 64)]
        ]
      )
    }
  }

  @Test func inventoryMismatchDescriptionIsBoundedAndShowsTheDifference() {
    let expected = (0..<1_000).map { "Expected/\($0).h" }
    let actual = (0..<1_000).map { "Actual/\($0).h" }
    let description = ArtifactPublisher.PublisherError.inventoryMismatch(
      expected: expected,
      actual: actual
    ).description

    #expect(description.count < 500)
    #expect(description.contains("missing Expected/0.h"))
    #expect(description.contains("unexpected Actual/0.h"))
    #expect(description.contains("and 995 more"))
  }
}

private final class PublisherFixture {
  let root: URL
  let publisher: ArtifactPublisher

  init() throws {
    root = try publisherTemporaryDirectory()
    publisher = try ArtifactPublisher(artifactBaseDirectory: root, sourceLabel: "iOS27")
    try publisher.prepareForLease()
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }

  func sourceFile(contents: String) throws -> URL {
    let directory = root.appendingPathComponent("source-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let url = directory.appendingPathComponent("artifact")
    try Data(contents.utf8).write(to: url)
    return url
  }

  func prepare(
    generationID: PrivateHeaderGeneration.GenerationID,
    targetID: String,
    relativePath: String,
    contents: String,
    allowLegacyMigration: Bool = false
  ) throws -> ArtifactPublisher.PreparedGeneration {
    var draft = try publisher.beginDraft(
      generationID: generationID,
      allowLegacyMigration: allowLegacyMigration
    )
    let source = try sourceFile(contents: contents)
    draft = try publisher.applyCompletedTarget(
      targetID: targetID,
      files: [try PrivateHeaderGeneration.ArtifactPath(relativePath): source],
      to: draft
    )
    return try publisher.prepareGeneration(draft, planFingerprint: "fingerprint")
  }

  func publish(_ prepared: ArtifactPublisher.PreparedGeneration) throws {
    try publisher.movePreparedGeneration(prepared)
    try publisher.switchCurrent(to: prepared.generationID)
    try publisher.ensureStablePointer()
  }
}

private func publisherTemporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "PrivateHeaderKitPublisherTests-\(UUID().uuidString)",
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
  return url
}
