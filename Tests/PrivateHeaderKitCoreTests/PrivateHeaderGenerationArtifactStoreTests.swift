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

    @Test func cleanupCanRemoveManagedDirectories() throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let managedDirectory = try PrivateHeaderGeneration.ArtifactPath("SystemLibrary/Foo.bundle")

        try writeFile("SystemLibrary/Foo.bundle/Headers/Foo.h", in: root)
        try writeFile("SystemLibrary/Foo.bundle/Modules/Foo.swiftinterface", in: root)

        let result = try PrivateHeaderGeneration.ArtifactStore.cleanupManagedArtifacts(
            in: root,
            artifacts: [managedDirectory]
        )

        #expect(result.deletedArtifacts == [managedDirectory])
        #expect(!pathExists("SystemLibrary/Foo.bundle", in: root))
        #expect(!pathExists("SystemLibrary", in: root))
        #expect(directoryExists(root))
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
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PrivateHeaderGenerationArtifactStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func writeFile(_ relativePath: String, in root: URL) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("contents".utf8).write(to: url)
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
