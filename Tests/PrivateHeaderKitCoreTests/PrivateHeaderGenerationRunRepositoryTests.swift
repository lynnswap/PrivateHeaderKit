import Foundation
import Testing

import PrivateHeaderKitCore

@Suite
struct PrivateHeaderGenerationRunRepositoryTests {
    @Test func exposesStateAndRunPaths() throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let repository = PrivateHeaderGeneration.RunRepository(stateDirectory: root)

        #expect(repository.manifestURL == root.appendingPathComponent("manifest.json"))
        #expect(repository.runsDirectory == root.appendingPathComponent("runs", isDirectory: true))
        #expect(
            try repository.runRecordURL(for: "run-001")
                == root.appendingPathComponent("runs/run-001/run.json")
        )
        #expect(
            try repository.logsDirectory(for: "run-001")
                == root.appendingPathComponent("runs/run-001/logs", isDirectory: true)
        )
        #expect(
            try repository.stagingDirectory(for: "run-001")
                == root.appendingPathComponent("runs/run-001/staging", isDirectory: true)
        )
    }

    @Test func writeManifestAndRunCreateDirectoriesAndRoundTripPrettyJSON() throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let repository = PrivateHeaderGeneration.RunRepository(stateDirectory: root)
        let manifest = try makeManifest(stateDirectory: root)
        let run = try makeRunRecord(runID: "run-001", manifest: manifest)

        try repository.writeManifest(manifest)
        try repository.writeRun(run)

        let decodedManifest = try repository.readManifest()
        let decodedRun = try repository.readRun(id: "run-001")
        let manifestJSON = try String(contentsOf: repository.manifestURL, encoding: .utf8)
        let runJSON = try String(
            contentsOf: repository.runRecordURL(for: "run-001"),
            encoding: .utf8
        )

        #expect(decodedManifest == manifest)
        #expect(decodedRun == run)
        #expect(directoryExists(try repository.logsDirectory(for: "run-001")))
        #expect(directoryExists(try repository.stagingDirectory(for: "run-001")))
        #expect(manifestJSON.contains("\n  \"layout\" : \"headers\""))
        #expect(runJSON.contains("\n  \"runID\" : \"run-001\""))
    }

    @Test func readManifestAndLatestRunReturnNilWhenAbsent() throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let repository = PrivateHeaderGeneration.RunRepository(stateDirectory: root)

        #expect(try repository.readManifest() == nil)
        #expect(try repository.readLatestRun() == nil)
    }

    @Test func readLatestRunUsesManifestLatestRunIDWhenPresent() throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let repository = PrivateHeaderGeneration.RunRepository(stateDirectory: root)
        let manifest = try makeManifest(stateDirectory: root, latestRunID: "run-002")
        let oldRun = try makeRunRecord(runID: "run-001", manifest: manifest)
        let latestRun = try makeRunRecord(runID: "run-002", manifest: manifest)

        try repository.writeManifest(manifest)
        try repository.writeRun(oldRun)
        try repository.writeRun(latestRun)

        #expect(try repository.readLatestRun() == latestRun)
    }

    @Test func readLatestRunReturnsNilWhenManifestHasNoExistingLatestRun() throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let repository = PrivateHeaderGeneration.RunRepository(stateDirectory: root)
        let noLatestManifest = try makeManifest(stateDirectory: root, latestRunID: nil)
        let missingLatestManifest = try makeManifest(stateDirectory: root, latestRunID: "run-missing")

        #expect(try repository.readLatestRun(from: noLatestManifest) == nil)
        #expect(try repository.readLatestRun(from: missingLatestManifest) == nil)
    }

    @Test func readManifestSurfacesDecodeErrors() throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let repository = PrivateHeaderGeneration.RunRepository(stateDirectory: root)

        try repository.prepareStateDirectory()
        try Data(#"{ "schemaVersion": "not-an-int" }"#.utf8).write(
            to: repository.manifestURL,
            options: [.atomic]
        )

        #expect(throws: DecodingError.self) {
            _ = try repository.readManifest()
        }
    }

    @Test func pruneRunHistoryKeepsLatestTenRunDirectories() throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let repository = PrivateHeaderGeneration.RunRepository(stateDirectory: root)
        let baseDate = Date(timeIntervalSince1970: 1_000)
        let runs = try (0..<12).map { index in
            let runID = "run-\(index)"
            try repository.prepareRunDirectories(for: runID)
            try writeMarker("marker.txt", in: repository.runDirectory(for: runID))
            return PrivateHeaderGeneration.RunSummary(
                runID: runID,
                startedAt: baseDate.addingTimeInterval(TimeInterval(index))
            )
        }

        let result = try repository.pruneRunHistory(from: runs)

        #expect(result.retainedRunIDs == [
            "run-11",
            "run-10",
            "run-9",
            "run-8",
            "run-7",
            "run-6",
            "run-5",
            "run-4",
            "run-3",
            "run-2",
        ])
        #expect(result.prunedRunIDs == ["run-0", "run-1"])
        #expect(!directoryExists(try repository.runDirectory(for: "run-0")))
        #expect(!directoryExists(try repository.runDirectory(for: "run-1")))
        #expect(directoryExists(try repository.runDirectory(for: "run-2")))
        #expect(directoryExists(try repository.runDirectory(for: "run-11")))
    }

    @Test func rejectsUnsafeRunIDsBeforeCreatingDirectories() throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let repository = PrivateHeaderGeneration.RunRepository(stateDirectory: root)

        #expect(throws: PrivateHeaderGeneration.RunRepositoryError.self) {
            try repository.prepareRunDirectories(for: "../outside")
        }
        #expect(!directoryExists(root.appendingPathComponent("runs", isDirectory: true)))
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PrivateHeaderGenerationRunRepositoryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeManifest(
    stateDirectory: URL,
    latestRunID: String? = "run-001"
) throws -> PrivateHeaderGeneration.Manifest {
    let source = try PrivateHeaderGeneration.Source(
        platform: .iOS,
        version: "27.0",
        build: "24A5355q"
    )
    let root = stateDirectory.deletingLastPathComponent()
    let updatedAt = Date(timeIntervalSince1970: 1_000)

    return PrivateHeaderGeneration.Manifest(
        schemaVersion: 1,
        toolVersion: "0.1.0",
        source: PrivateHeaderGeneration.SourceRecord(source: source),
        output: PrivateHeaderGeneration.OutputRecord(
            baseDirectory: root.path,
            artifactDirectory: root.appendingPathComponent("generated-headers", isDirectory: true).path,
            stateDirectory: stateDirectory.path
        ),
        layout: .headers,
        latestRunID: latestRunID,
        targets: [
            PrivateHeaderGeneration.TargetRecord(
                id: "framework:Foo",
                displayName: "Foo.framework",
                kind: "framework",
                status: .partial,
                phases: [
                    PrivateHeaderGeneration.PhaseRecord(name: "static ObjC", status: .completed),
                    PrivateHeaderGeneration.PhaseRecord(
                        name: "Swift interface",
                        status: .failed,
                        failureSummary: "swift interface failed"
                    ),
                ],
                artifacts: [
                    try PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo/Foo.h"),
                    try PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo/Foo.swiftinterface"),
                ],
                lastRunID: latestRunID,
                updatedAt: updatedAt,
                failureSummary: "swift interface failed"
            ),
        ],
        updatedAt: updatedAt
    )
}

private func makeRunRecord(
    runID: String,
    manifest: PrivateHeaderGeneration.Manifest
) throws -> PrivateHeaderGeneration.RunRecord {
    let artifact = try PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo/Foo.h")
    let plan = PrivateHeaderGeneration.RunPlanRecord(
        source: manifest.source,
        output: manifest.output,
        layout: manifest.layout,
        targetIDs: ["framework:Foo"],
        execution: PrivateHeaderGeneration.ExecutionRecord(
            mode: "simulator",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
            deviceName: "iPhone 17",
            deviceUDID: "SIM-001",
            clonePolicy: "reuseOrCreate",
            helperEnvironment: [:]
        )
    )

    return PrivateHeaderGeneration.RunRecord(
        runID: runID,
        schemaVersion: 1,
        toolVersion: "0.1.0",
        plan: plan,
        startedAt: Date(timeIntervalSince1970: 1_000),
        endedAt: Date(timeIntervalSince1970: 1_100),
        status: .partial,
        targetResults: [
            PrivateHeaderGeneration.RunTargetRecord(
                targetID: "framework:Foo",
                status: .commitFailed,
                phases: [
                    PrivateHeaderGeneration.PhaseRecord(name: "commit", status: .failed),
                ],
                artifacts: [],
                attemptedArtifacts: [artifact],
                failureSummary: "commit failed"
            ),
        ],
        attemptedArtifacts: [artifact],
        logs: [
            PrivateHeaderGeneration.RunLogRecord(
                kind: "stderr",
                relativePath: try PrivateHeaderGeneration.ArtifactPath("runs/\(runID)/logs/stderr.log")
            ),
        ]
    )
}

private func writeMarker(_ name: String, in directory: URL) throws {
    try Data("marker".utf8).write(
        to: directory.appendingPathComponent(name),
        options: [.atomic]
    )
}

private func directoryExists(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
    return exists && isDirectory.boolValue
}
