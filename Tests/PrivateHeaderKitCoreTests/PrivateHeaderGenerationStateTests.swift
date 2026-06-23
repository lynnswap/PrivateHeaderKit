import Foundation
import Testing

import PrivateHeaderKitCore

@Suite
struct PrivateHeaderGenerationManifestTests {
    @Test func manifestRoundTripsAsPrettyJSON() throws {
        let manifest = try makeManifest()

        let data = try PrivateHeaderGeneration.StateJSON.encode(manifest)
        let json = try #require(String(data: data, encoding: .utf8))
        let decoded = try PrivateHeaderGeneration.StateJSON.decode(
            PrivateHeaderGeneration.Manifest.self,
            from: data
        )

        #expect(decoded == manifest)
        #expect(json.contains("\n  \"layout\" : \"headers\""))
        #expect(json.contains("\"schemaVersion\" : 1"))
        #expect(json.contains("\"artifacts\" : [\n"))
    }

    @Test func manifestStoreWritesAndReadsJSON() throws {
        let manifest = try makeManifest()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateHeaderKitStateTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("manifest.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        try PrivateHeaderGeneration.StateJSON.write(manifest, to: url)
        let decoded = try PrivateHeaderGeneration.StateJSON.read(
            PrivateHeaderGeneration.Manifest.self,
            from: url
        )

        #expect(decoded == manifest)
    }

    @Test func stateJSONPreservesFractionalSecondDates() throws {
        let updatedAt = Date(timeIntervalSinceReferenceDate: .pi)
        let manifest = try makeManifest(updatedAt: updatedAt)

        let data = try PrivateHeaderGeneration.StateJSON.encode(manifest)
        let json = try #require(String(data: data, encoding: .utf8))
        let decoded = try PrivateHeaderGeneration.StateJSON.decode(
            PrivateHeaderGeneration.Manifest.self,
            from: data
        )

        #expect(decoded.updatedAt == manifest.updatedAt)
        #expect(json.contains("\"updatedAt\" : 3.141592653589793"))
    }

    @Test func manifestEncodingKeepsRequiredNullFields() throws {
        let source = try PrivateHeaderGeneration.Source(
            platform: .iOS,
            version: "27.0",
            build: nil
        )
        let updatedAt = Date(timeIntervalSinceReferenceDate: 42)
        let manifest = PrivateHeaderGeneration.Manifest(
            schemaVersion: 1,
            toolVersion: "0.1.0",
            source: PrivateHeaderGeneration.SourceRecord(source: source),
            output: PrivateHeaderGeneration.OutputRecord(
                baseDirectory: "/tmp/PrivateHeaderKit",
                artifactDirectory: "/tmp/PrivateHeaderKit/generated-headers",
                stateDirectory: "/tmp/PrivateHeaderKit/.state"
            ),
            layout: .headers,
            latestRunID: nil,
            targets: [
                PrivateHeaderGeneration.TargetRecord(
                    id: "framework:Foo",
                    displayName: "Foo.framework",
                    kind: "framework",
                    status: .completed,
                    phases: [
                        PrivateHeaderGeneration.PhaseRecord(name: "static ObjC", status: .completed),
                    ],
                    artifacts: [
                        try PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo/Foo.h"),
                    ],
                    lastRunID: nil,
                    updatedAt: updatedAt,
                    failureSummary: nil
                ),
            ],
            updatedAt: updatedAt
        )

        let data = try PrivateHeaderGeneration.StateJSON.encode(manifest)
        let json = try #require(String(data: data, encoding: .utf8))
        let decoded = try PrivateHeaderGeneration.StateJSON.decode(
            PrivateHeaderGeneration.Manifest.self,
            from: data
        )

        #expect(decoded == manifest)
        #expect(json.contains("\"build\" : null"))
        #expect(json.contains("\"latestRunID\" : null"))
        #expect(json.contains("\"lastRunID\" : null"))
        #expect(json.contains("\"failureSummary\" : null"))
    }

    @Test func manifestDecodingRejectsMissingRequiredNullableFields() throws {
        let manifest = try makeManifest()
        let data = try PrivateHeaderGeneration.StateJSON.encode(manifest)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "latestRunID")
        let missingKeyData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        #expect(throws: DecodingError.self) {
            _ = try PrivateHeaderGeneration.StateJSON.decode(
                PrivateHeaderGeneration.Manifest.self,
                from: missingKeyData
            )
        }
    }

    @Test func artifactPathRejectsAbsoluteTraversalAndEmptyPaths() {
        #expect(throws: PrivateHeaderGeneration.StateValidationError.self) {
            _ = try PrivateHeaderGeneration.ArtifactPath("/System/Library/Foo.h")
        }
        #expect(throws: PrivateHeaderGeneration.StateValidationError.self) {
            _ = try PrivateHeaderGeneration.ArtifactPath("Frameworks/../Foo.h")
        }
        #expect(throws: PrivateHeaderGeneration.StateValidationError.self) {
            _ = try PrivateHeaderGeneration.ArtifactPath("")
        }
    }

    @Test func artifactPathValidationRunsDuringJSONDecode() throws {
        let data = Data(#""../escape.h""#.utf8)

        #expect(throws: PrivateHeaderGeneration.StateValidationError.self) {
            _ = try PrivateHeaderGeneration.StateJSON.decode(
                PrivateHeaderGeneration.ArtifactPath.self,
                from: data
            )
        }
    }
}

@Suite
struct PrivateHeaderGenerationRunRecordTests {
    @Test func runRecordRoundTripsTargetResultsAndAttemptedArtifacts() throws {
        let run = try makeRunRecord()
        let data = try PrivateHeaderGeneration.StateJSON.encode(run)
        let decoded = try PrivateHeaderGeneration.StateJSON.decode(
            PrivateHeaderGeneration.RunRecord.self,
            from: data
        )

        #expect(decoded == run)
        #expect(decoded.status == .partial)
        #expect(decoded.targetResults.first?.status == .commitFailed)
        #expect(decoded.attemptedArtifacts.map(\.rawValue) == ["Frameworks/Foo/Foo.h"])
        #expect(decoded.plan.execution.runtimeIdentifier == "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
    }

    @Test func runRecordReadDefaultsMissingPlanExecutionForOldHistory() throws {
        let run = try makeRunRecord()
        let data = try PrivateHeaderGeneration.StateJSON.encode(run)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var plan = try #require(object["plan"] as? [String: Any])
        plan.removeValue(forKey: "execution")
        object["plan"] = plan
        let oldHistoryData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateHeaderKitRunRecordTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("run-001.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try oldHistoryData.write(to: url, options: [.atomic])

        let decoded = try PrivateHeaderGeneration.StateJSON.read(
            PrivateHeaderGeneration.RunRecord.self,
            from: url
        )

        #expect(decoded.schemaVersion == 1)
        #expect(decoded.plan.execution == .unspecified)
    }

    @Test func runPlanRecordsExecutionMetadata() throws {
        let manifest = try makeManifest()
        let first = PrivateHeaderGeneration.RunPlanRecord(
            source: manifest.source,
            output: manifest.output,
            layout: manifest.layout,
            targetIDs: ["framework:Foo"],
            execution: makeExecutionRecord(deviceUDID: "SIM-001")
        )
        let second = PrivateHeaderGeneration.RunPlanRecord(
            source: manifest.source,
            output: manifest.output,
            layout: manifest.layout,
            targetIDs: ["framework:Foo"],
            execution: makeExecutionRecord(deviceUDID: "SIM-002")
        )

        let data = try PrivateHeaderGeneration.StateJSON.encode(first)
        let json = try #require(String(data: data, encoding: .utf8))
        let decoded = try PrivateHeaderGeneration.StateJSON.decode(
            PrivateHeaderGeneration.RunPlanRecord.self,
            from: data
        )

        #expect(first != second)
        #expect(decoded == first)
        #expect(json.contains("\"runtimeIdentifier\" : \"com.apple.CoreSimulator.SimRuntime.iOS-27-0\""))
        #expect(json.contains("\"deviceUDID\" : \"SIM-001\""))
        #expect(json.contains("\"clonePolicy\" : \"reuseOrCreate\""))
        #expect(json.contains("\"execution\" : {"))
    }

    @Test func runPlanFourArgumentInitializerDefaultsExecutionMetadata() throws {
        let manifest = try makeManifest()
        let plan = PrivateHeaderGeneration.RunPlanRecord(
            source: manifest.source,
            output: manifest.output,
            layout: manifest.layout,
            targetIDs: ["framework:Foo"]
        )

        #expect(plan.execution == .unspecified)
    }

    @Test func runPlanDecodingRejectsMissingExecutionRequiredNullableFields() throws {
        let manifest = try makeManifest()
        let plan = PrivateHeaderGeneration.RunPlanRecord(
            source: manifest.source,
            output: manifest.output,
            layout: manifest.layout,
            targetIDs: ["framework:Foo"],
            execution: makeExecutionRecord()
        )
        let data = try PrivateHeaderGeneration.StateJSON.encode(plan)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var execution = try #require(object["execution"] as? [String: Any])
        execution.removeValue(forKey: "runtimeIdentifier")
        object["execution"] = execution
        let missingKeyData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        #expect(throws: DecodingError.self) {
            _ = try PrivateHeaderGeneration.StateJSON.decode(
                PrivateHeaderGeneration.RunPlanRecord.self,
                from: missingKeyData
            )
        }
    }

    @Test func runRecordEncodingKeepsRequiredNullFields() throws {
        let manifest = try makeManifest()
        let run = PrivateHeaderGeneration.RunRecord(
            runID: "run-002",
            schemaVersion: 1,
            toolVersion: "0.1.0",
            plan: PrivateHeaderGeneration.RunPlanRecord(
                source: manifest.source,
                output: manifest.output,
                layout: manifest.layout,
                targetIDs: ["framework:Foo"],
                execution: makeExecutionRecord()
            ),
            startedAt: Date(timeIntervalSinceReferenceDate: 42),
            endedAt: nil,
            status: .running,
            targetResults: [
                PrivateHeaderGeneration.RunTargetRecord(
                    targetID: "framework:Foo",
                    status: .running,
                    phases: [
                        PrivateHeaderGeneration.PhaseRecord(name: "static ObjC", status: .running),
                    ],
                    artifacts: [],
                    attemptedArtifacts: [],
                    failureSummary: nil
                ),
            ],
            attemptedArtifacts: [],
            logs: []
        )

        let data = try PrivateHeaderGeneration.StateJSON.encode(run)
        let json = try #require(String(data: data, encoding: .utf8))
        let decoded = try PrivateHeaderGeneration.StateJSON.decode(
            PrivateHeaderGeneration.RunRecord.self,
            from: data
        )

        #expect(decoded == run)
        #expect(json.contains("\"endedAt\" : null"))
        #expect(json.contains("\"failureSummary\" : null"))
    }

    @Test func runRecordDecodingRejectsMissingRequiredNullableFields() throws {
        let run = try makeRunRecord()
        let data = try PrivateHeaderGeneration.StateJSON.encode(run)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "endedAt")
        let missingKeyData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        #expect(throws: DecodingError.self) {
            _ = try PrivateHeaderGeneration.StateJSON.decode(
                PrivateHeaderGeneration.RunRecord.self,
                from: missingKeyData
            )
        }
    }

    @Test func runHistoryRetentionKeepsLatestTenRuns() {
        let base = Date(timeIntervalSince1970: 1_000)
        let runs = (0..<12).map { index in
            PrivateHeaderGeneration.RunSummary(
                runID: "run-\(index)",
                startedAt: base.addingTimeInterval(TimeInterval(index))
            )
        }

        let retained = PrivateHeaderGeneration.RunHistoryRetention.retainedRunIDs(from: runs)

        #expect(retained == [
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
    }

    @Test func runHistoryRetentionUsesRunIDAsStableTieBreaker() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let runs = [
            PrivateHeaderGeneration.RunSummary(runID: "run-a", startedAt: startedAt),
            PrivateHeaderGeneration.RunSummary(runID: "run-c", startedAt: startedAt),
            PrivateHeaderGeneration.RunSummary(runID: "run-b", startedAt: startedAt),
        ]

        let retained = PrivateHeaderGeneration.RunHistoryRetention.retainedRunIDs(from: runs, limit: 2)

        #expect(retained == ["run-c", "run-b"])
    }
}

private func makeManifest(
    updatedAt: Date = Date(timeIntervalSince1970: 1_000)
) throws -> PrivateHeaderGeneration.Manifest {
    let source = try PrivateHeaderGeneration.Source(
        platform: .iOS,
        version: "27.0",
        build: "24A5355q"
    )
    let root = URL(fileURLWithPath: "/tmp/PrivateHeaderKit", isDirectory: true)
    let output = PrivateHeaderGeneration.Output(
        artifactBaseDirectory: root.appendingPathComponent("generated-headers", isDirectory: true),
        stateBaseDirectory: root.appendingPathComponent(".state", isDirectory: true)
    )
    let plan = PrivateHeaderGeneration.makePlan(source: source, output: output)
    return PrivateHeaderGeneration.Manifest(
        schemaVersion: 1,
        toolVersion: "0.1.0",
        source: PrivateHeaderGeneration.SourceRecord(source: source),
        output: PrivateHeaderGeneration.OutputRecord(plan: plan, baseDirectory: root),
        layout: .headers,
        latestRunID: "run-001",
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
                lastRunID: "run-001",
                updatedAt: updatedAt,
                failureSummary: "swift interface failed"
            ),
        ],
        updatedAt: updatedAt
    )
}

private func makeRunRecord() throws -> PrivateHeaderGeneration.RunRecord {
    let manifest = try makeManifest()
    let artifact = try PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo/Foo.h")
    let plan = PrivateHeaderGeneration.RunPlanRecord(
        source: manifest.source,
        output: manifest.output,
        layout: manifest.layout,
        targetIDs: ["framework:Foo"],
        execution: makeExecutionRecord()
    )

    return PrivateHeaderGeneration.RunRecord(
        runID: "run-001",
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
                relativePath: try PrivateHeaderGeneration.ArtifactPath("runs/run-001/logs/stderr.log")
            ),
        ]
    )
}

private func makeExecutionRecord(
    deviceUDID: String = "SIM-001"
) -> PrivateHeaderGeneration.ExecutionRecord {
    PrivateHeaderGeneration.ExecutionRecord(
        mode: "simulator",
        runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
        deviceName: "iPhone 17",
        deviceUDID: deviceUDID,
        clonePolicy: "reuseOrCreate",
        helperEnvironment: [
            "SIMCTL_CHILD_PRIVATEHEADERKIT_DUMP_QUALITY": "max",
        ]
    )
}
