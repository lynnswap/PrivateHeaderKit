import Foundation
import Testing

import PrivateHeaderKitCore

@Suite
struct PrivateHeaderGenerationResumeTests {
    @Test func completedTargetsWithExistingManagedArtifactsAreSkipped() throws {
        let plan = try makeRunPlan(targetIDs: ["framework:Foo", "framework:Bar"])
        let manifest = try makeManifest(
            targets: [
                makeTarget("framework:Foo", status: .completed),
                makeTarget("framework:Bar", status: .completed),
            ]
        )

        let summary = PrivateHeaderGeneration.makeResumeSummary(
            plan: plan,
            manifest: manifest,
            artifactExists: existingArtifacts([
                "Frameworks/Foo/Foo.h",
                "Frameworks/Bar/Bar.h",
            ])
        )

        #expect(summary.targetIDsToRun == [])
        #expect(
            summary.counts == PrivateHeaderGeneration.ResumeTargetCounts(
                total: 2,
                completed: 2,
                partial: 0,
                failed: 0,
                interrupted: 0,
                commitFailed: 0,
                stale: 0,
                pending: 0
            )
        )
    }

    @Test func failedPartialInterruptedCommitFailedAndStaleTargetsRerun() throws {
        let targetIDs = [
            "framework:Failed",
            "framework:Partial",
            "framework:Interrupted",
            "framework:CommitFailed",
            "framework:Stale",
        ]
        let plan = try makeRunPlan(targetIDs: targetIDs)
        let manifest = try makeManifest(
            targets: [
                makeTarget("framework:Failed", status: .failed),
                makeTarget("framework:Partial", status: .partial),
                makeTarget("framework:Interrupted", status: .interrupted),
                makeTarget("framework:CommitFailed", status: .commitFailed),
                makeTarget("framework:Stale", status: .stale),
            ]
        )

        let summary = PrivateHeaderGeneration.makeResumeSummary(
            plan: plan,
            manifest: manifest,
            artifactExists: existingArtifacts([])
        )

        #expect(summary.targetIDsToRun == targetIDs)
        #expect(summary.counts.failed == 1)
        #expect(summary.counts.partial == 1)
        #expect(summary.counts.interrupted == 1)
        #expect(summary.counts.commitFailed == 1)
        #expect(summary.counts.stale == 1)
        #expect(summary.counts.unfinished == 5)
    }

    @Test func missingManagedArtifactMakesCompletedTargetStale() throws {
        let plan = try makeRunPlan(targetIDs: ["framework:Foo"])
        let manifest = try makeManifest(
            targets: [
                makeTarget(
                    "framework:Foo",
                    status: .completed,
                    artifacts: [
                        "Frameworks/Foo/Foo.h",
                        "Frameworks/Foo/Foo.swiftinterface",
                    ]
                ),
            ]
        )

        let summary = PrivateHeaderGeneration.makeResumeSummary(
            plan: plan,
            manifest: manifest,
            artifactExists: existingArtifacts([
                "Frameworks/Foo/Foo.h",
            ])
        )

        #expect(summary.targets == [
            PrivateHeaderGeneration.ResumeTargetDecision(
                targetID: "framework:Foo",
                status: .stale
            ),
        ])
        #expect(summary.targetIDsToRun == ["framework:Foo"])
        #expect(summary.counts.completed == 0)
        #expect(summary.counts.stale == 1)
    }

    @Test func missingManifestEntryIsPendingAndReruns() throws {
        let plan = try makeRunPlan(targetIDs: ["framework:Foo", "framework:New"])
        let manifest = try makeManifest(
            targets: [
                makeTarget("framework:Foo", status: .completed),
            ]
        )

        let summary = PrivateHeaderGeneration.makeResumeSummary(
            plan: plan,
            manifest: manifest,
            artifactExists: existingArtifacts([
                "Frameworks/Foo/Foo.h",
            ])
        )

        #expect(summary.targetIDsToRun == ["framework:New"])
        #expect(summary.counts.completed == 1)
        #expect(summary.counts.pending == 1)
    }

    @Test func expandedSelectedTargetSetIsCompatibleAndTreatsNewTargetsAsPending() throws {
        let plan = try makeRunPlan(targetIDs: ["framework:Foo", "framework:Bar"])
        let manifest = try makeManifest(
            targets: [
                makeTarget("framework:Foo", status: .completed),
            ]
        )
        let latestRun = try makeRunRecord(
            plan: makeRunPlan(targetIDs: ["framework:Foo"])
        )
        let artifactExists = existingArtifacts([
            "Frameworks/Foo/Foo.h",
        ])

        #expect(
            PrivateHeaderGeneration.evaluateResumeCompatibility(
                plan: plan,
                manifest: manifest,
                latestRun: latestRun
            ) == .compatible
        )

        let summary = PrivateHeaderGeneration.makeResumeSummary(
            plan: plan,
            manifest: manifest,
            latestRun: latestRun,
            artifactExists: artifactExists
        )

        #expect(summary.targets == [
            PrivateHeaderGeneration.ResumeTargetDecision(
                targetID: "framework:Foo",
                status: .completed
            ),
            PrivateHeaderGeneration.ResumeTargetDecision(
                targetID: "framework:Bar",
                status: .pending
            ),
        ])
        #expect(summary.targetIDsToRun == ["framework:Bar"])
        #expect(
            summary.counts == PrivateHeaderGeneration.ResumeTargetCounts(
                total: 2,
                completed: 1,
                partial: 0,
                failed: 0,
                interrupted: 0,
                commitFailed: 0,
                stale: 0,
                pending: 1
            )
        )

        #expect(
            PrivateHeaderGeneration.nonInteractiveResumeDecision(
                plan: plan,
                manifest: manifest,
                latestRun: latestRun,
                resumeRequested: false,
                artifactExists: artifactExists
            ) == .resumeRequired(summary)
        )
        #expect(
            PrivateHeaderGeneration.nonInteractiveResumeDecision(
                plan: plan,
                manifest: manifest,
                latestRun: latestRun,
                resumeRequested: true,
                artifactExists: artifactExists
            ) == .resume(summary)
        )
    }

    @Test func shrinkingSelectedTargetSetMismatchReturnsStructuredReason() throws {
        let plan = try makeRunPlan(targetIDs: ["framework:Foo"])
        let manifest = try makeManifest(
            targets: [
                makeTarget("framework:Foo", status: .completed),
                makeTarget("framework:Bar", status: .completed),
            ]
        )
        let latestRun = try makeRunRecord(
            plan: makeRunPlan(targetIDs: ["framework:Foo", "framework:Bar"])
        )

        #expect(
            PrivateHeaderGeneration.evaluateResumeCompatibility(
                plan: plan,
                manifest: manifest,
                latestRun: latestRun
            ) == .incompatible(
                [
                    .selectedTargetSetMismatch(
                        expected: ["framework:Foo"],
                        actual: ["framework:Bar", "framework:Foo"],
                        record: .run
                    ),
                ]
            )
        )
    }

    @Test func selectedTargetSetIsNotInferredFromManifestWithoutLatestRun() throws {
        let plan = try makeRunPlan(targetIDs: ["framework:Foo", "framework:Bar"])
        let manifest = try makeManifest(
            targets: [
                makeTarget("framework:Foo", status: .partial),
            ]
        )

        #expect(
            PrivateHeaderGeneration.evaluateResumeCompatibility(
                plan: plan,
                manifest: manifest
            ) == .incompatible(
                [
                    .missingLatestRun(runID: "run-001"),
                ]
            )
        )
    }

    @Test func executionMetadataMismatchReturnsStructuredReason() throws {
        let expectedExecution = makeExecutionRecord()
        let plan = try makeRunPlan(
            targetIDs: ["framework:Foo"],
            execution: expectedExecution
        )
        let manifest = try makeManifest(
            targets: [
                makeTarget("framework:Foo", status: .partial),
            ]
        )
        let mismatchedExecutions = [
            makeExecutionRecord(runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-0"),
            makeExecutionRecord(deviceName: "iPhone 16"),
            makeExecutionRecord(deviceUDID: "SIM-002"),
            makeExecutionRecord(clonePolicy: "alwaysClone"),
            makeExecutionRecord(helperEnvironment: [
                "SIMCTL_CHILD_PRIVATEHEADERKIT_DUMP_QUALITY": "min",
            ]),
        ]

        for actualExecution in mismatchedExecutions {
            let latestRun = try makeRunRecord(
                plan: makeRunPlan(
                    targetIDs: ["framework:Foo"],
                    execution: actualExecution
                )
            )

            #expect(
                PrivateHeaderGeneration.evaluateResumeCompatibility(
                    plan: plan,
                    manifest: manifest,
                    latestRun: latestRun
                ) == .incompatible(
                    [
                        .executionMismatch(
                            expected: expectedExecution,
                            actual: actualExecution,
                            record: .run
                        ),
                    ]
                )
            )
        }
    }

    @Test func sourceBuildMismatchReturnsStructuredReason() throws {
        let plan = try makeRunPlan(targetIDs: ["framework:Foo"])
        let expectedSource = try makeSource()
        let actualSource = try makeSource(build: "24B1")
        let manifest = try makeManifest(
            source: actualSource,
            targets: [
                makeTarget("framework:Foo", status: .completed),
            ]
        )

        #expect(
            PrivateHeaderGeneration.evaluateResumeCompatibility(
                plan: plan,
                manifest: manifest
            ) == .incompatible(
                [
                    .sourceBuildMismatch(
                        expected: expectedSource,
                        actual: actualSource,
                        record: .manifest
                    ),
                ]
            )
        )
    }

    @Test func layoutMismatchReturnsStructuredReason() throws {
        let plan = try makeRunPlan(targetIDs: ["framework:Foo"])
        let manifest = try makeManifest(
            layout: .bundle,
            targets: [
                makeTarget("framework:Foo", status: .completed),
            ]
        )

        #expect(
            PrivateHeaderGeneration.evaluateResumeCompatibility(
                plan: plan,
                manifest: manifest
            ) == .incompatible(
                [
                    .layoutMismatch(
                        expected: .headers,
                        actual: .bundle,
                        record: .manifest
                    ),
                ]
            )
        )
    }

    @Test func outputMismatchReturnsStructuredReason() throws {
        let plan = try makeRunPlan(targetIDs: ["framework:Foo"])
        let mismatchedOutput = makeOutput(baseDirectory: "/Volumes/Data/Headers")
        let manifest = try makeManifest(
            output: mismatchedOutput,
            targets: [
                makeTarget("framework:Foo", status: .completed),
            ]
        )

        #expect(
            PrivateHeaderGeneration.evaluateResumeCompatibility(
                plan: plan,
                manifest: manifest
            ) == .incompatible(
                [
                    .outputMismatch(
                        expected: makeOutput(),
                        actual: mismatchedOutput,
                        record: .manifest
                    ),
                ]
            )
        )
    }

    @Test func unsupportedManifestSchemaReturnsStructuredReason() throws {
        let plan = try makeRunPlan(targetIDs: ["framework:Foo"])
        let manifest = try makeManifest(
            schemaVersion: 99,
            targets: [
                makeTarget("framework:Foo", status: .completed),
            ]
        )

        #expect(
            PrivateHeaderGeneration.evaluateResumeCompatibility(
                plan: plan,
                manifest: manifest,
                supportedSchemaVersions: [1]
            ) == .incompatible(
                [
                    .unsupportedManifestSchema(actual: 99, supported: [1]),
                ]
            )
        )
    }

    @Test func unsupportedRunSchemaReturnsStructuredReason() throws {
        let plan = try makeRunPlan(targetIDs: ["framework:Foo"])
        let manifest = try makeManifest(
            targets: [
                makeTarget("framework:Foo", status: .completed),
            ]
        )
        let latestRun = try makeRunRecord(plan: plan, schemaVersion: 99)

        #expect(
            PrivateHeaderGeneration.evaluateResumeCompatibility(
                plan: plan,
                manifest: manifest,
                latestRun: latestRun,
                supportedSchemaVersions: [1]
            ) == .incompatible(
                [
                    .unsupportedRunSchema(actual: 99, supported: [1]),
                ]
            )
        )
    }

    @Test func nonInteractiveUnfinishedCompatibleRunRequiresExplicitResume() throws {
        let plan = try makeRunPlan(targetIDs: ["framework:Foo"])
        let manifest = try makeManifest(
            targets: [
                makeTarget("framework:Foo", status: .partial),
            ]
        )
        let latestRun = try makeRunRecord(plan: plan)
        let summary = PrivateHeaderGeneration.makeResumeSummary(
            plan: plan,
            manifest: manifest,
            latestRun: latestRun,
            artifactExists: existingArtifacts([])
        )

        #expect(
            PrivateHeaderGeneration.nonInteractiveResumeDecision(
                plan: plan,
                manifest: manifest,
                latestRun: latestRun,
                resumeRequested: false,
                artifactExists: existingArtifacts([])
            ) == .resumeRequired(summary)
        )
    }

    @Test func nonInteractiveExplicitResumeAllowsCompatibleUnfinishedRun() throws {
        let plan = try makeRunPlan(targetIDs: ["framework:Foo"])
        let manifest = try makeManifest(
            targets: [
                makeTarget("framework:Foo", status: .partial),
            ]
        )
        let latestRun = try makeRunRecord(plan: plan)
        let summary = PrivateHeaderGeneration.makeResumeSummary(
            plan: plan,
            manifest: manifest,
            latestRun: latestRun,
            artifactExists: existingArtifacts([])
        )

        #expect(
            PrivateHeaderGeneration.nonInteractiveResumeDecision(
                plan: plan,
                manifest: manifest,
                latestRun: latestRun,
                resumeRequested: true,
                artifactExists: existingArtifacts([])
            ) == .resume(summary)
        )
    }
}

private func makeSource(
    build: String = "24A5355q"
) throws -> PrivateHeaderGeneration.SourceRecord {
    let source = try PrivateHeaderGeneration.Source(
        platform: .iOS,
        version: "27.0",
        build: build
    )
    return PrivateHeaderGeneration.SourceRecord(source: source)
}

private func makeOutput(
    baseDirectory: String = "/tmp/PrivateHeaderKit"
) -> PrivateHeaderGeneration.OutputRecord {
    PrivateHeaderGeneration.OutputRecord(
        baseDirectory: baseDirectory,
        artifactDirectory: "\(baseDirectory)/iOS27.0(24A5355q)",
        stateDirectory: "\(baseDirectory)/.state/iOS27.0(24A5355q)"
    )
}

private func makeRunPlan(
    targetIDs: [String],
    source: PrivateHeaderGeneration.SourceRecord? = nil,
    output: PrivateHeaderGeneration.OutputRecord? = nil,
    layout: PrivateHeaderGeneration.Layout = .headers,
    execution: PrivateHeaderGeneration.ExecutionRecord? = nil
) throws -> PrivateHeaderGeneration.RunPlanRecord {
    try PrivateHeaderGeneration.RunPlanRecord(
        source: source ?? makeSource(),
        output: output ?? makeOutput(),
        layout: layout,
        targetIDs: targetIDs,
        execution: execution ?? makeExecutionRecord()
    )
}

private func makeManifest(
    schemaVersion: Int = 1,
    source: PrivateHeaderGeneration.SourceRecord? = nil,
    output: PrivateHeaderGeneration.OutputRecord? = nil,
    layout: PrivateHeaderGeneration.Layout = .headers,
    targets: [PrivateHeaderGeneration.TargetRecord]
) throws -> PrivateHeaderGeneration.Manifest {
    PrivateHeaderGeneration.Manifest(
        schemaVersion: schemaVersion,
        toolVersion: "0.1.0",
        source: try source ?? makeSource(),
        output: output ?? makeOutput(),
        layout: layout,
        latestRunID: "run-001",
        targets: targets,
        updatedAt: Date(timeIntervalSince1970: 1_100)
    )
}

private func makeRunRecord(
    plan: PrivateHeaderGeneration.RunPlanRecord,
    schemaVersion: Int = 1
) throws -> PrivateHeaderGeneration.RunRecord {
    PrivateHeaderGeneration.RunRecord(
        runID: "run-001",
        schemaVersion: schemaVersion,
        toolVersion: "0.1.0",
        plan: plan,
        startedAt: Date(timeIntervalSince1970: 1_000),
        endedAt: nil,
        status: .running,
        targetResults: [],
        attemptedArtifacts: [],
        logs: []
    )
}

private func makeTarget(
    _ id: String,
    status: PrivateHeaderGeneration.TargetStatus,
    artifacts: [String]? = nil
) throws -> PrivateHeaderGeneration.TargetRecord {
    let displayName = String(id.split(separator: ":").last ?? Substring(id))
    let artifactPaths = try (artifacts ?? ["Frameworks/\(displayName)/\(displayName).h"]).map {
        try PrivateHeaderGeneration.ArtifactPath($0)
    }
    return PrivateHeaderGeneration.TargetRecord(
        id: id,
        displayName: "\(displayName).framework",
        kind: "framework",
        status: status,
        phases: [],
        artifacts: artifactPaths,
        lastRunID: "run-001",
        updatedAt: Date(timeIntervalSince1970: 1_100),
        failureSummary: status == .completed ? nil : "\(status.rawValue) target"
    )
}

private func existingArtifacts(
    _ paths: Set<String>
) -> PrivateHeaderGeneration.ArtifactExistence {
    { paths.contains($0.rawValue) }
}

private func existingArtifacts(
    _ paths: [String]
) -> PrivateHeaderGeneration.ArtifactExistence {
    existingArtifacts(Set(paths))
}

private func makeExecutionRecord(
    mode: String = "simulator",
    runtimeIdentifier: String? = "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
    deviceName: String? = "iPhone 17",
    deviceUDID: String? = "SIM-001",
    clonePolicy: String? = "reuseOrCreate",
    helperEnvironment: [String: String] = [
        "SIMCTL_CHILD_PRIVATEHEADERKIT_DUMP_QUALITY": "max",
    ]
) -> PrivateHeaderGeneration.ExecutionRecord {
    PrivateHeaderGeneration.ExecutionRecord(
        mode: mode,
        runtimeIdentifier: runtimeIdentifier,
        deviceName: deviceName,
        deviceUDID: deviceUDID,
        clonePolicy: clonePolicy,
        helperEnvironment: helperEnvironment
    )
}
