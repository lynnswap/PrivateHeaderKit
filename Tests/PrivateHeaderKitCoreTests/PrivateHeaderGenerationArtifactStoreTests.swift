import Darwin
import Foundation
import Testing

import PrivateHeaderKitCore

@Suite
struct PrivateHeaderGenerationArtifactStoreTests {
    @Test func cleanupPreservesUnknownFilesInManagedParentDirectories() throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let managed = try PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo/Foo.h")

        try writeFile("Frameworks/Foo/Foo.h", in: root)
        try writeFile("Frameworks/Foo/Notes.txt", in: root)

        let result = try PrivateHeaderGeneration.ArtifactStore.cleanupManagedArtifacts(
            in: root,
            artifacts: [managed]
        )

        #expect(result.deletedArtifacts == [managed])
        #expect(result.missingArtifacts.isEmpty)
        #expect(!pathExists("Frameworks/Foo/Foo.h", in: root))
        #expect(pathExists("Frameworks/Foo/Notes.txt", in: root))
        #expect(directoryExists("Frameworks/Foo", in: root))
    }

    @Test func cleanupPrunesEmptyParentDirectoriesUpToArtifactRoot() throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let managed = try PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo/Foo.h")

        try writeFile("Frameworks/Foo/Foo.h", in: root)

        let result = try PrivateHeaderGeneration.ArtifactStore.cleanupManagedArtifacts(
            in: root,
            artifacts: [managed]
        )

        #expect(result.prunedDirectories.map(\.rawValue) == ["Frameworks", "Frameworks/Foo"])
        #expect(!pathExists("Frameworks/Foo/Foo.h", in: root))
        #expect(!pathExists("Frameworks/Foo", in: root))
        #expect(!pathExists("Frameworks", in: root))
        #expect(directoryExists(root))
    }

    @Test func cleanupPreservesArtifactRootItself() throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try writeFile("Root.h", in: root)

        try PrivateHeaderGeneration.ArtifactStore.cleanupManagedArtifacts(
            in: root,
            artifacts: [try PrivateHeaderGeneration.ArtifactPath("Root.h")]
        )

        #expect(directoryExists(root))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func cleanupTreatsMissingManagedPathsAsSuccess() throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let missing = try PrivateHeaderGeneration.ArtifactPath("Frameworks/Missing/Missing.h")

        let result = try PrivateHeaderGeneration.ArtifactStore.cleanupManagedArtifacts(
            in: root,
            artifacts: [missing]
        )

        #expect(result.deletedArtifacts.isEmpty)
        #expect(result.missingArtifacts == [missing])
        #expect(result.prunedDirectories.isEmpty)
        #expect(directoryExists(root))
    }

    @Test func cleanupCandidatesDedupeManifestAndAttemptedArtifactsDeterministically() throws {
        let alpha = try PrivateHeaderGeneration.ArtifactPath("Frameworks/Alpha/Alpha.h")
        let beta = try PrivateHeaderGeneration.ArtifactPath("Frameworks/Beta/Beta.h")
        let gamma = try PrivateHeaderGeneration.ArtifactPath("Frameworks/Gamma/Gamma.h")

        let candidates = PrivateHeaderGeneration.ArtifactStore.cleanupCandidates(
            manifestArtifacts: [beta, alpha, beta],
            attemptedArtifacts: [gamma, alpha]
        )

        #expect(candidates.map(\.rawValue) == [
            "Frameworks/Alpha/Alpha.h",
            "Frameworks/Beta/Beta.h",
            "Frameworks/Gamma/Gamma.h",
        ])
    }

    @Test func cleanupDeletesEmptyManagedDirectoryCandidatesOnly() throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let managedDirectory = try PrivateHeaderGeneration.ArtifactPath("SystemLibrary/Foo.bundle")

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("SystemLibrary/Foo.bundle", isDirectory: true),
            withIntermediateDirectories: true
        )

        let result = try PrivateHeaderGeneration.ArtifactStore.cleanupManagedArtifacts(
            in: root,
            artifacts: [managedDirectory]
        )

        #expect(result.deletedArtifacts == [managedDirectory])
        #expect(result.prunedDirectories.map(\.rawValue) == ["SystemLibrary"])
        #expect(!pathExists("SystemLibrary/Foo.bundle", in: root))
        #expect(!pathExists("SystemLibrary", in: root))
        #expect(directoryExists(root))
    }

    @Test func cleanupPreservesNonEmptyManagedDirectoryCandidatesWithUnknownDescendants() throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let managedDirectory = try PrivateHeaderGeneration.ArtifactPath("SystemLibrary/Foo.bundle")

        try writeFile("SystemLibrary/Foo.bundle/Headers/Foo.h", in: root)

        let result = try PrivateHeaderGeneration.ArtifactStore.cleanupManagedArtifacts(
            in: root,
            artifacts: [managedDirectory]
        )

        #expect(result.deletedArtifacts.isEmpty)
        #expect(result.missingArtifacts.isEmpty)
        #expect(result.prunedDirectories.isEmpty)
        #expect(pathExists("SystemLibrary/Foo.bundle/Headers/Foo.h", in: root))
        #expect(directoryExists("SystemLibrary/Foo.bundle", in: root))
    }

    @Test func cleanupRemovesManagedDirectorySymlinkAndPreservesDestinationContents() throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let managedDirectory = try PrivateHeaderGeneration.ArtifactPath("SystemLibrary/Foo.bundle")
        let destination = root.appendingPathComponent("SystemLibrary/Targets/Foo.bundle", isDirectory: true)

        try writeFile("SystemLibrary/Targets/Foo.bundle/Headers/Foo.h", in: root)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("SystemLibrary/Foo.bundle"),
            withDestinationURL: destination
        )

        let result = try PrivateHeaderGeneration.ArtifactStore.cleanupManagedArtifacts(
            in: root,
            artifacts: [managedDirectory]
        )

        #expect(result.deletedArtifacts == [managedDirectory])
        #expect(result.missingArtifacts.isEmpty)
        #expect(result.prunedDirectories.isEmpty)
        #expect(!pathExists("SystemLibrary/Foo.bundle", in: root))
        #expect(pathExists("SystemLibrary/Targets/Foo.bundle/Headers/Foo.h", in: root))
        #expect(directoryExists("SystemLibrary/Targets/Foo.bundle", in: root))
    }

    @Test func cleanupRejectsResolvedPathsOutsideArtifactRoot() throws {
        let base = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: base)
        }
        let root = base.appendingPathComponent("artifacts", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try writeFile("Outside.h", in: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"),
            withDestinationURL: outside
        )

        #expect(throws: PrivateHeaderGeneration.ArtifactStoreError.self) {
            try PrivateHeaderGeneration.ArtifactStore.cleanupManagedArtifacts(
                in: root,
                artifacts: [try PrivateHeaderGeneration.ArtifactPath("link/Outside.h")]
            )
        }
        #expect(pathExists("Outside.h", in: outside))
    }

    @Test func cleanupPreflightsEscapingCandidatesBeforeDeletingAnyArtifacts() throws {
        let base = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: base)
        }
        let root = base.appendingPathComponent("artifacts", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try writeFile("Frameworks/Foo/Foo.h", in: root)
        try writeFile("Outside.h", in: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"),
            withDestinationURL: outside
        )

        #expect(throws: PrivateHeaderGeneration.ArtifactStoreError.self) {
            try PrivateHeaderGeneration.ArtifactStore.cleanupManagedArtifacts(
                in: root,
                artifacts: [
                    try PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo/Foo.h"),
                    try PrivateHeaderGeneration.ArtifactPath("link/Outside.h"),
                ]
            )
        }
        #expect(pathExists("Frameworks/Foo/Foo.h", in: root))
        #expect(pathExists("Outside.h", in: outside))
    }

    @Test func cleanupTreatsMissingLeafUnderSymlinkArtifactRootAsMissing() throws {
        let base = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: base)
        }
        let realRoot = base.appendingPathComponent("real-artifacts", isDirectory: true)
        let symlinkRoot = base.appendingPathComponent("artifact-link", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: symlinkRoot,
            withDestinationURL: realRoot
        )
        let missing = try PrivateHeaderGeneration.ArtifactPath("Frameworks/Missing/Missing.h")

        let result = try PrivateHeaderGeneration.ArtifactStore.cleanupManagedArtifacts(
            in: symlinkRoot,
            artifacts: [missing]
        )

        #expect(result.deletedArtifacts.isEmpty)
        #expect(result.missingArtifacts == [missing])
        #expect(result.prunedDirectories.isEmpty)
        #expect(directoryExists(realRoot))
        #expect(directoryExists(symlinkRoot))
    }

    @Test func commitRejectsIntermediateSymlinkWithoutModifyingExternalDirectory() throws {
        let base = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: base)
        }
        let staging = base.appendingPathComponent("staging", isDirectory: true)
        let root = base.appendingPathComponent("artifacts", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeFile("Generated.h", in: staging)
        try writeFile("sentinel", to: "Sentinel.txt", in: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Frameworks"),
            withDestinationURL: outside
        )
        let store = PrivateHeaderGeneration.ArtifactStore(artifactRoot: root)

        #expect(throws: PrivateHeaderGeneration.ArtifactStoreError.self) {
            _ = try store.prepareCommit(
                stagedSourceDirectory: staging,
                artifactRoot: try PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo/Headers"),
                artifacts: try artifactPaths("Frameworks/Foo/Headers/Generated.h")
            )
        }

        #expect(try fileContents("Sentinel.txt", in: outside) == "sentinel")
        #expect(!pathExists("Foo/Headers/Generated.h", in: outside))
        #expect(symbolicLinkExists("Frameworks", in: root))
        #expect(pathExists("Generated.h", in: staging))
    }

    @Test func commitRejectsLeafSymlinkWithoutReplacingLinkOrExternalFile() throws {
        let base = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: base)
        }
        let staging = base.appendingPathComponent("staging", isDirectory: true)
        let root = base.appendingPathComponent("artifacts", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try writeFile("replacement", to: "Generated.h", in: staging)
        try writeFile("external", to: "External.h", in: outside)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Frameworks/Foo/Headers", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Frameworks/Foo/Headers/Generated.h"),
            withDestinationURL: outside.appendingPathComponent("External.h")
        )
        let store = PrivateHeaderGeneration.ArtifactStore(artifactRoot: root)

        #expect(throws: PrivateHeaderGeneration.ArtifactStoreError.self) {
            _ = try store.prepareCommit(
                stagedSourceDirectory: staging,
                artifactRoot: try PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo/Headers"),
                artifacts: try artifactPaths("Frameworks/Foo/Headers/Generated.h")
            )
        }

        #expect(try fileContents("External.h", in: outside) == "external")
        #expect(symbolicLinkExists("Frameworks/Foo/Headers/Generated.h", in: root))
        #expect(pathExists("Generated.h", in: staging))
    }

    @Test func commitPreflightsAllDestinationsBeforeWritingAnyArtifact() throws {
        let base = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: base)
        }
        let staging = base.appendingPathComponent("staging", isDirectory: true)
        let root = base.appendingPathComponent("artifacts", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try writeFile("alpha", to: "A.h", in: staging)
        try writeFile("beta", to: "B.h", in: staging)
        try writeFile("external", to: "External.h", in: outside)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Frameworks/Foo/Headers", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Frameworks/Foo/Headers/B.h"),
            withDestinationURL: outside.appendingPathComponent("External.h")
        )
        let store = PrivateHeaderGeneration.ArtifactStore(artifactRoot: root)

        #expect(throws: PrivateHeaderGeneration.ArtifactStoreError.self) {
            _ = try store.prepareCommit(
                stagedSourceDirectory: staging,
                artifactRoot: try PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo/Headers"),
                artifacts: try artifactPaths(
                    "Frameworks/Foo/Headers/A.h",
                    "Frameworks/Foo/Headers/B.h"
                )
            )
        }

        #expect(!pathExists("Frameworks/Foo/Headers/A.h", in: root))
        #expect(symbolicLinkExists("Frameworks/Foo/Headers/B.h", in: root))
        #expect(try fileContents("External.h", in: outside) == "external")
        #expect(pathExists("A.h", in: staging))
        #expect(pathExists("B.h", in: staging))
    }

    @Test func commitMovesStagedFilesIntoNormalDestination() throws {
        let base = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: base)
        }
        let staging = base.appendingPathComponent("staging", isDirectory: true)
        let root = base.appendingPathComponent("artifacts", isDirectory: true)
        try writeFile("replacement", to: "Generated.h", in: staging)
        try writeFile("swift", to: "Nested/Foo.swiftinterface", in: staging)
        try writeFile(
            "previous",
            to: "Frameworks/Foo/Headers/Generated.h",
            in: root
        )
        let store = PrivateHeaderGeneration.ArtifactStore(artifactRoot: root)

        let plan = try store.prepareCommit(
            stagedSourceDirectory: staging,
            artifactRoot: try PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo/Headers"),
            artifacts: try artifactPaths(
                "Frameworks/Foo/Headers/Generated.h",
                "Frameworks/Foo/Headers/Nested/Foo.swiftinterface"
            )
        )
        try store.commit(plan)

        #expect(
            try fileContents("Frameworks/Foo/Headers/Generated.h", in: root) == "replacement"
        )
        #expect(
            try fileContents(
                "Frameworks/Foo/Headers/Nested/Foo.swiftinterface",
                in: root
            ) == "swift"
        )
        #expect(!pathExists("Generated.h", in: staging))
        #expect(!pathExists("Nested/Foo.swiftinterface", in: staging))
    }

    @Test func commitUsesSymlinkArtifactRootAsCanonicalBoundary() throws {
        let base = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: base)
        }
        let staging = base.appendingPathComponent("staging", isDirectory: true)
        let realRoot = base.appendingPathComponent("real-artifacts", isDirectory: true)
        let symlinkRoot = base.appendingPathComponent("artifact-link", isDirectory: true)
        try writeFile("generated", to: "Generated.h", in: staging)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: symlinkRoot,
            withDestinationURL: realRoot
        )
        let store = PrivateHeaderGeneration.ArtifactStore(artifactRoot: symlinkRoot)

        let plan = try store.prepareCommit(
            stagedSourceDirectory: staging,
            artifactRoot: try PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo/Headers"),
            artifacts: try artifactPaths("Frameworks/Foo/Headers/Generated.h")
        )
        try store.commit(plan)

        #expect(
            try fileContents("Frameworks/Foo/Headers/Generated.h", in: realRoot) == "generated"
        )
        #expect(symbolicLinkExists("artifact-link", in: base))
    }

    @Test func commitRejectsSymlinkStagingRoot() throws {
        let base = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: base)
        }
        let realStaging = base.appendingPathComponent("real-staging", isDirectory: true)
        let symlinkStaging = base.appendingPathComponent("staging-link", isDirectory: true)
        let root = base.appendingPathComponent("artifacts", isDirectory: true)
        try writeFile("generated", to: "Generated.h", in: realStaging)
        try FileManager.default.createSymbolicLink(
            at: symlinkStaging,
            withDestinationURL: realStaging
        )
        let store = PrivateHeaderGeneration.ArtifactStore(artifactRoot: root)

        #expect(throws: PrivateHeaderGeneration.ArtifactStoreError.self) {
            _ = try store.prepareCommit(
                stagedSourceDirectory: symlinkStaging,
                artifactRoot: try PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo/Headers"),
                artifacts: try artifactPaths("Frameworks/Foo/Headers/Generated.h")
            )
        }

        #expect(try fileContents("Generated.h", in: realStaging) == "generated")
        #expect(!pathExists("Frameworks/Foo/Headers/Generated.h", in: root))
    }

    @Test func commitRejectsSymlinkStagingDescendant() throws {
        let base = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: base)
        }
        let staging = base.appendingPathComponent("staging", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        let root = base.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try writeFile("external", to: "External.h", in: outside)
        try FileManager.default.createSymbolicLink(
            at: staging.appendingPathComponent("Linked.h"),
            withDestinationURL: outside.appendingPathComponent("External.h")
        )
        let store = PrivateHeaderGeneration.ArtifactStore(artifactRoot: root)

        #expect(throws: PrivateHeaderGeneration.ArtifactStoreError.self) {
            _ = try store.prepareCommit(
                stagedSourceDirectory: staging,
                artifactRoot: try PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo/Headers"),
                artifacts: try artifactPaths("Frameworks/Foo/Headers/Linked.h")
            )
        }

        #expect(try fileContents("External.h", in: outside) == "external")
        #expect(!pathExists("Frameworks/Foo/Headers/Linked.h", in: root))
    }

    @Test func commitRechecksDestinationAfterPreflight() throws {
        let base = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: base)
        }
        let staging = base.appendingPathComponent("staging", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        let root = base.appendingPathComponent("artifacts", isDirectory: true)
        try writeFile("replacement", to: "Generated.h", in: staging)
        try writeFile("external", to: "External.h", in: outside)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = PrivateHeaderGeneration.ArtifactStore(artifactRoot: root)
        let plan = try store.prepareCommit(
            stagedSourceDirectory: staging,
            artifactRoot: try PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo/Headers"),
            artifacts: try artifactPaths("Frameworks/Foo/Headers/Generated.h")
        )
        let destination = root.appendingPathComponent(
            "Frameworks/Foo/Headers/Generated.h"
        )
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: destination,
            withDestinationURL: outside.appendingPathComponent("External.h")
        )

        #expect(throws: PrivateHeaderGeneration.ArtifactStoreError.self) {
            try store.commit(plan)
        }

        #expect(try fileContents("External.h", in: outside) == "external")
        #expect(symbolicLinkExists("Frameworks/Foo/Headers/Generated.h", in: root))
        #expect(pathExists("Generated.h", in: staging))
    }

    @Test func commitIgnoresUnownedStagedFiles() throws {
        let base = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: base)
        }
        let staging = base.appendingPathComponent("staging", isDirectory: true)
        let root = base.appendingPathComponent("artifacts", isDirectory: true)
        try writeFile("owned", to: "Generated.h", in: staging)
        try writeFile("unowned", to: "Notes.txt", in: staging)
        let store = PrivateHeaderGeneration.ArtifactStore(artifactRoot: root)

        let plan = try store.prepareCommit(
            stagedSourceDirectory: staging,
            artifactRoot: try PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo/Headers"),
            artifacts: try artifactPaths("Frameworks/Foo/Headers/Generated.h")
        )
        try store.commit(plan)

        #expect(try fileContents("Frameworks/Foo/Headers/Generated.h", in: root) == "owned")
        #expect(!pathExists("Frameworks/Foo/Headers/Notes.txt", in: root))
        #expect(try fileContents("Notes.txt", in: staging) == "unowned")
    }

    @Test func commitRejectsNonRegularStagedLeaf() throws {
        let base = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: base)
        }
        let staging = base.appendingPathComponent("staging", isDirectory: true)
        let root = base.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let fifo = staging.appendingPathComponent("Generated.h")
        let status = fifo.path.withCString { mkfifo($0, 0o600) }
        #expect(status == 0)
        let store = PrivateHeaderGeneration.ArtifactStore(artifactRoot: root)

        #expect(throws: PrivateHeaderGeneration.ArtifactStoreError.self) {
            _ = try store.prepareCommit(
                stagedSourceDirectory: staging,
                artifactRoot: try PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo/Headers"),
                artifacts: try artifactPaths("Frameworks/Foo/Headers/Generated.h")
            )
        }

        #expect(!pathExists("Frameworks/Foo/Headers/Generated.h", in: root))
    }

    @Test func commitRejectsArtifactOutsideDeclaredRoot() throws {
        let base = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: base)
        }
        let staging = base.appendingPathComponent("staging", isDirectory: true)
        let root = base.appendingPathComponent("artifacts", isDirectory: true)
        try writeFile("generated", to: "Generated.h", in: staging)
        let store = PrivateHeaderGeneration.ArtifactStore(artifactRoot: root)

        #expect(throws: PrivateHeaderGeneration.ArtifactStoreError.self) {
            _ = try store.prepareCommit(
                stagedSourceDirectory: staging,
                artifactRoot: try PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo/Headers"),
                artifacts: try artifactPaths("Frameworks/Bar/Headers/Generated.h")
            )
        }

        #expect(pathExists("Generated.h", in: staging))
        #expect(!pathExists("Frameworks/Bar/Headers/Generated.h", in: root))
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PrivateHeaderGenerationArtifactStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func artifactPaths(
    _ rawValues: String...
) throws -> [PrivateHeaderGeneration.ArtifactPath] {
    try rawValues.map(PrivateHeaderGeneration.ArtifactPath.init)
}

private func writeFile(_ relativePath: String, in root: URL) throws {
    try writeFile("contents", to: relativePath, in: root)
}

private func writeFile(_ contents: String, to relativePath: String, in root: URL) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: url)
}

private func fileContents(_ relativePath: String, in root: URL) throws -> String {
    String(decoding: try Data(contentsOf: root.appendingPathComponent(relativePath)), as: UTF8.self)
}

private func pathExists(_ relativePath: String, in root: URL) -> Bool {
    FileManager.default.fileExists(
        atPath: root.appendingPathComponent(relativePath).path
    )
}

private func directoryExists(_ relativePath: String, in root: URL) -> Bool {
    directoryExists(root.appendingPathComponent(relativePath, isDirectory: true))
}

private func directoryExists(_ url: URL) -> Bool {
    var isDirectory = ObjCBool(false)
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        && isDirectory.boolValue
}

private func symbolicLinkExists(_ relativePath: String, in root: URL) -> Bool {
    do {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent(relativePath).path
        )
        return attributes[.type] as? FileAttributeType == .typeSymbolicLink
    } catch {
        return false
    }
}
