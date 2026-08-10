import Foundation
import PrivateHeaderKitHelperProtocol
import Testing

@testable import PrivateHeaderKitCore

@Suite
struct PrivateHeaderGenerationExecutorTests {
    @Test func executorDiscoversTargetRunsRawDumpAndCommitsStateSeparately() async throws {
        let fixture = try ExecutorFixture()
        defer { fixture.remove() }
        try fixture.createFramework("Foo.framework")

        let runner = RecordingRawDumpRunner()
        let plan = try fixture.makePlan(targetRequest: .query("Foo"))
        let executor = makeGenerationExecutor(
            rawDumpRunner: { invocation in try await runner.run(invocation) },
            runIDGenerator: { "run-001" },
            dateProvider: fixedDates()
        )

        let result = try await executor.run(.init(plan: plan))

        let invocation = try #require(runner.invocations.first)
        #expect(runner.invocations.count == 1)
        #expect(invocation.inputPath == fixture.systemRoot.appendingPathComponent("System/Library/Frameworks/Foo.framework").path)
        #expect(invocation.command.contains(invocation.inputPath))
        #expect(invocation.command.contains(fixture.helperURLs.host.path))
        #expect(invocation.command.contains("__raw-dump"))
        #expect(
            fileExists(
                plan.artifactDirectory.appendingPathComponent("Frameworks/Foo/Headers/Generated.h")
            )
        )
        #expect(result.generatedTargets.map(\.description) == ["framework:Foo.framework"])
        #expect(result.runID == "run-001")
        #expect(result.manifestURL == plan.stateDirectory.appendingPathComponent("manifest.json"))
        #expect(result.runRecordURL == plan.stateDirectory.appendingPathComponent("runs/run-001/run.json"))

        let manifest = try PrivateHeaderGeneration.StateJSON.read(
            PrivateHeaderGeneration.Manifest.self,
            from: result.manifestURL
        )
        let run = try PrivateHeaderGeneration.StateJSON.read(
            PrivateHeaderGeneration.RunRecord.self,
            from: result.runRecordURL
        )
        #expect(manifest.output.artifactDirectory == plan.artifactDirectory.path)
        #expect(manifest.output.stateDirectory == plan.stateDirectory.path)
        #expect(manifest.targets.map(\.id) == ["framework:Foo.framework"])
        #expect(manifest.targets.first?.status == .completed)
        #expect(manifest.targets.first?.artifacts.map(\.rawValue) == ["Frameworks/Foo/Headers/Generated.h"])
        #expect(run.status == .completed)
        #expect(run.targetResults.first?.attemptedArtifacts.map(\.rawValue) == ["Frameworks/Foo/Headers/Generated.h"])
    }

    @Test func executorReportsGenerationProgress() async throws {
        let fixture = try ExecutorFixture()
        defer { fixture.remove() }
        try fixture.createFramework("Foo.framework")

        let runner = RecordingRawDumpRunner()
        let progress = ProgressEventRecorder()
        let plan = try fixture.makePlan(targetRequest: .query("Foo"))
        let executor = makeGenerationExecutor(
            rawDumpRunner: { invocation in try await runner.run(invocation) },
            runIDGenerator: { "run-001" },
            dateProvider: fixedDates()
        )

        _ = try await executor.run(.init(
            plan: plan,
            progressReporter: { progress.record($0) }
        ))

        #expect(progress.events == [
            .runStarted(runID: "run-001", totalTargetCount: 1),
            .targetStarted(index: 1, total: 1, displayName: "Foo"),
            .targetFinished(
                index: 1,
                total: 1,
                displayName: "Foo",
                status: .completed
            ),
            .runFinished(runID: "run-001", status: .completed),
        ])
    }

    @Test func executorHoldsStateLockWhileGeneratingTargets() async throws {
        let fixture = try ExecutorFixture()
        defer { fixture.remove() }
        try fixture.createFramework("Foo.framework")

        let plan = try fixture.makePlan(targetRequest: .query("Foo"))
        let repository = PrivateHeaderGeneration.RunRepository(plan: plan)
        let probe = StateLockProbe(repository: repository)
        let runner = RecordingRawDumpRunner()
        let executor = makeGenerationExecutor(
            rawDumpRunner: { invocation in
                await probe.recordNestedLockAttempt()
                return try await runner.run(invocation)
            },
            runIDGenerator: { "run-001" },
            dateProvider: fixedDates()
        )

        _ = try await executor.run(.init(plan: plan))

        #expect(probe.unavailablePath == repository.lockURL.path)
        #expect(probe.unexpectedlyAcquired == false)
        #expect(probe.unexpectedError == nil)
        #expect(fileExists(repository.lockURL))
    }

    @Test func completedTargetWithManagedArtifactsIsSkippedOnResume() async throws {
        let fixture = try ExecutorFixture()
        defer { fixture.remove() }
        try fixture.createFramework("Foo.framework")

        let firstRunner = RecordingRawDumpRunner()
        let plan = try fixture.makePlan(targetRequest: .query("Foo"))
        let firstExecutor = makeGenerationExecutor(
            rawDumpRunner: { invocation in try await firstRunner.run(invocation) },
            runIDGenerator: { "run-001" },
            dateProvider: fixedDates()
        )
        _ = try await firstExecutor.run(.init(plan: plan))

        let secondRunner = RecordingRawDumpRunner()
        let secondExecutor = makeGenerationExecutor(
            rawDumpRunner: { invocation in try await secondRunner.run(invocation) },
            runIDGenerator: { "run-002" },
            dateProvider: fixedDates()
        )
        let result = try await secondExecutor.run(.init(plan: plan))

        #expect(secondRunner.invocations.isEmpty)
        #expect(result.generatedTargets.isEmpty)
        let run = try PrivateHeaderGeneration.StateJSON.read(
            PrivateHeaderGeneration.RunRecord.self,
            from: result.runRecordURL
        )
        #expect(run.status == .completed)
        #expect(run.targetResults.map(\.status) == [.skipped])
    }

    @Test func unfinishedCompatibleStateRequiresExplicitResume() async throws {
        let fixture = try ExecutorFixture()
        defer { fixture.remove() }
        try fixture.createFramework("Foo.framework")

        let targetID = "framework:Foo.framework"
        let artifact = try PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo/Headers/Generated.h")
        let plan = try fixture.makePlan(targetRequest: .query("Foo"))
        try writeFile(
            "old",
            to: plan.artifactDirectory.appendingPathComponent(artifact.rawValue)
        )
        try fixture.writeState(
            plan: plan,
            runID: "run-prev",
            targetID: targetID,
            status: .partial,
            artifacts: [artifact],
            runStatus: .partial,
            attemptedArtifacts: []
        )

        let runner = RecordingRawDumpRunner()
        let executor = makeGenerationExecutor(
            rawDumpRunner: { invocation in try await runner.run(invocation) },
            runIDGenerator: { "run-002" },
            dateProvider: fixedDates()
        )

        await #expect(throws: PrivateHeaderGeneration.GenerationError.self) {
            _ = try await executor.run(.init(plan: plan))
        }
        #expect(runner.invocations.isEmpty)
    }

    @Test func availableResumeSummaryIsNilWithoutManifest() async throws {
        let fixture = try ExecutorFixture()
        defer { fixture.remove() }
        try fixture.createFramework("Foo.framework")

        let plan = try fixture.makePlan(targetRequest: .query("Foo"))

        let inventoryRunner = RecordingSharedCacheInventoryRunner(
            data: try inventoryData(imagePaths: ["/usr/lib/libobjc.A.dylib"])
        )
        let executor = makeGenerationExecutor(
            sharedCacheInventoryRunner: { invocation in
                try await inventoryRunner.run(invocation)
            }
        )
        let summary = try await executor.availableResumeSummary(for: plan)

        #expect(summary == nil)
        #expect(inventoryRunner.invocations.isEmpty)
    }

    #if os(macOS)
    @Test func availableResumeSummaryReturnsCompatibleUnfinishedState() async throws {
        let fixture = try ExecutorFixture()
        defer { fixture.remove() }
        try fixture.createFramework("Foo.framework")

        let targetID = "framework:Foo.framework"
        let artifact = try PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo/Headers/Generated.h")
        let plan = try fixture.makePlan(targetRequest: .query("Foo"))
        try fixture.writeState(
            plan: plan,
            runID: "run-prev",
            targetID: targetID,
            status: .partial,
            artifacts: [artifact],
            runStatus: .partial,
            attemptedArtifacts: []
        )

        let availableSummary = try await PrivateHeaderGeneration.availableResumeSummary(
            source: plan.source,
            output: plan.output,
            options: plan.options
        )
        let summary = try #require(availableSummary)

        #expect(summary.latestRunID == "run-prev")
        #expect(summary.targetIDsToRun == [targetID])
        #expect(summary.counts.unfinished == 1)
    }
    #endif

    @Test func sharedCacheInventoryAddsCacheOnlyTargetAndPinsRawDumpToCacheUUID() async throws {
        let fixture = try ExecutorFixture()
        defer { fixture.remove() }
        let cacheUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let inventoryRunner = RecordingSharedCacheInventoryRunner(
            data: try inventoryData(
                cacheUUID: cacheUUID,
                imagePaths: ["/usr/lib/libobjc.A.dylib"]
            )
        )
        let rawRunner = RecordingRawDumpRunner()
        let plan = try fixture.makePlan(
            targetRequest: .query("libobjc.A.dylib"),
            rawDumpingOptions: .init(useSharedCache: true)
        )
        let executor = makeGenerationExecutor(
            rawDumpRunner: { invocation in try await rawRunner.run(invocation) },
            sharedCacheInventoryRunner: { invocation in
                try await inventoryRunner.run(invocation)
            },
            runIDGenerator: { "run-cache" },
            dateProvider: fixedDates()
        )

        let result = try await executor.run(.init(plan: plan))

        #expect(inventoryRunner.invocations.count == 1)
        let invocation = try #require(rawRunner.invocations.first)
        #expect(invocation.inputPath == "/usr/lib/libobjc.A.dylib")
        #expect(invocation.command.contains("--expected-cache-uuid"))
        #expect(invocation.command.contains(cacheUUID.uuidString.lowercased()))
        let run = try PrivateHeaderGeneration.StateJSON.read(
            PrivateHeaderGeneration.RunRecord.self,
            from: result.runRecordURL
        )
        #expect(run.plan.execution.cacheUUID == cacheUUID)
    }

    @Test func disabledSharedCacheNeverLoadsInventory() async throws {
        let fixture = try ExecutorFixture()
        defer { fixture.remove() }
        try fixture.createFramework("Foo.framework")
        let inventoryRunner = RecordingSharedCacheInventoryRunner(
            data: try inventoryData(imagePaths: ["/usr/lib/libobjc.A.dylib"])
        )
        let rawRunner = RecordingRawDumpRunner()
        let executor = makeGenerationExecutor(
            rawDumpRunner: { invocation in try await rawRunner.run(invocation) },
            sharedCacheInventoryRunner: { invocation in
                try await inventoryRunner.run(invocation)
            },
            runIDGenerator: { "run-no-cache" },
            dateProvider: fixedDates()
        )

        _ = try await executor.run(.init(
            plan: fixture.makePlan(targetRequest: .query("Foo"))
        ))

        #expect(inventoryRunner.invocations.isEmpty)
        #expect(rawRunner.invocations.first?.command.contains("--expected-cache-uuid") == false)
    }

    @Test func inventoryFailureStopsBeforeRawDump() async throws {
        let fixture = try ExecutorFixture()
        defer { fixture.remove() }
        try fixture.createFramework("Foo.framework")
        let rawRunner = RecordingRawDumpRunner()
        let executor = makeGenerationExecutor(
            rawDumpRunner: { invocation in try await rawRunner.run(invocation) },
            sharedCacheInventoryRunner: { _ in throw InventoryTestError.failed }
        )
        let plan = try fixture.makePlan(
            targetRequest: .query("Foo"),
            rawDumpingOptions: .init(useSharedCache: true)
        )

        await #expect(throws: InventoryTestError.self) {
            _ = try await executor.run(.init(plan: plan))
        }
        #expect(rawRunner.invocations.isEmpty)
    }

    @Test func emptyLoadedSharedCacheStopsBeforeFilesystemOnlyDiscovery() async throws {
        let fixture = try ExecutorFixture()
        defer { fixture.remove() }
        try fixture.createFramework("Foo.framework")
        let rawRunner = RecordingRawDumpRunner()
        let executor = makeGenerationExecutor(
            rawDumpRunner: { invocation in try await rawRunner.run(invocation) },
            sharedCacheInventoryRunner: { _ in try inventoryData(imagePaths: []) }
        )
        let plan = try fixture.makePlan(
            targetRequest: .query("Foo"),
            rawDumpingOptions: .init(useSharedCache: true)
        )

        await #expect(throws: PrivateHeaderGeneration.GenerationError.self) {
            _ = try await executor.run(.init(plan: plan))
        }
        #expect(rawRunner.invocations.isEmpty)
    }

    @Test func inventoryCancellationPropagatesWithoutDecodeOrRawDump() async throws {
        let fixture = try ExecutorFixture()
        defer { fixture.remove() }
        try fixture.createFramework("Foo.framework")
        let rawRunner = RecordingRawDumpRunner()
        let executor = makeGenerationExecutor(
            rawDumpRunner: { invocation in try await rawRunner.run(invocation) },
            sharedCacheInventoryRunner: { _ in throw CancellationError() }
        )
        let plan = try fixture.makePlan(
            targetRequest: .query("Foo"),
            rawDumpingOptions: .init(useSharedCache: true)
        )

        await #expect(throws: CancellationError.self) {
            _ = try await executor.run(.init(plan: plan))
        }
        #expect(rawRunner.invocations.isEmpty)
    }

    @Test func cancellationBeforeFirstTargetPersistsInterruptedRunAndManifest() async throws {
        let fixture = try ExecutorFixture()
        defer { fixture.remove() }
        try fixture.createFramework("Foo.framework")
        try fixture.createFramework("Bar.framework")

        let rawRunner = RecordingRawDumpRunner()
        let plan = try fixture.makePlan(
            targetRequest: .identifiers([
                "framework:Foo.framework",
                "framework:Bar.framework",
            ])
        )
        let executor = makeGenerationExecutor(
            rawDumpRunner: { invocation in try await rawRunner.run(invocation) },
            runIDGenerator: { "run-001" },
            dateProvider: fixedDates()
        )
        let task = Task {
            try await executor.run(.init(
                plan: plan,
                progressReporter: { event in
                    guard case .runStarted = event else {
                        return
                    }
                    withUnsafeCurrentTask { task in
                        task?.cancel()
                    }
                }
            ))
        }

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }

        #expect(rawRunner.invocations.isEmpty)
        let repository = PrivateHeaderGeneration.RunRepository(plan: plan)
        let run = try #require(try repository.readRun(id: "run-001"))
        let manifest = try #require(try repository.readManifest())
        let interruptedRunTarget = try #require(run.targetResults.first)
        let interruptedManifestTarget = try #require(manifest.targets.first)

        #expect(run.status == .interrupted)
        #expect(run.endedAt != nil)
        #expect(run.targetResults.count == 1)
        #expect(interruptedRunTarget.targetID == "framework:Foo.framework")
        #expect(interruptedRunTarget.status == .interrupted)
        #expect(interruptedRunTarget.phases.isEmpty)
        #expect(interruptedRunTarget.artifacts.isEmpty)
        #expect(interruptedRunTarget.attemptedArtifacts.isEmpty)
        #expect(interruptedRunTarget.failureSummary == "cancelled")
        #expect(manifest.latestRunID == "run-001")
        #expect(manifest.targets.count == 1)
        #expect(interruptedManifestTarget.id == "framework:Foo.framework")
        #expect(interruptedManifestTarget.status == .interrupted)
        #expect(interruptedManifestTarget.phases.isEmpty)
        #expect(interruptedManifestTarget.artifacts.isEmpty)
        #expect(interruptedManifestTarget.failureSummary == "cancelled")
    }

    @Test func cancellationInLastTargetFinishedPreservesCompletedTargetAndInterruptsRun() async throws {
        let fixture = try ExecutorFixture()
        defer { fixture.remove() }
        try fixture.createFramework("Foo.framework")

        let rawRunner = RecordingRawDumpRunner()
        let progress = ProgressEventRecorder()
        let plan = try fixture.makePlan(targetRequest: .query("Foo"))
        let executor = makeGenerationExecutor(
            rawDumpRunner: { invocation in try await rawRunner.run(invocation) },
            runIDGenerator: { "run-001" },
            dateProvider: fixedDates()
        )
        let task = Task {
            try await executor.run(.init(
                plan: plan,
                progressReporter: { event in
                    progress.record(event)
                    guard case .targetFinished = event else {
                        return
                    }
                    withUnsafeCurrentTask { task in
                        task?.cancel()
                    }
                }
            ))
        }

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }

        #expect(rawRunner.invocations.count == 1)
        #expect(
            fileExists(
                plan.artifactDirectory.appendingPathComponent("Frameworks/Foo/Headers/Generated.h")
            )
        )
        let repository = PrivateHeaderGeneration.RunRepository(plan: plan)
        let run = try #require(try repository.readRun(id: "run-001"))
        let manifest = try #require(try repository.readManifest())
        let runTarget = try #require(run.targetResults.first)
        let manifestTarget = try #require(manifest.targets.first)

        #expect(run.status == .interrupted)
        #expect(run.endedAt != nil)
        #expect(runTarget.status == .completed)
        #expect(runTarget.artifacts.map(\.rawValue) == [
            "Frameworks/Foo/Headers/Generated.h",
        ])
        #expect(manifest.latestRunID == "run-001")
        #expect(manifest.updatedAt == run.endedAt)
        #expect(manifestTarget.status == .completed)
        #expect(manifestTarget.artifacts.map(\.rawValue) == [
            "Frameworks/Foo/Headers/Generated.h",
        ])
        #expect(progress.events.last == .runFinished(
            runID: "run-001",
            status: .interrupted
        ))
    }

    @Test func cancellationInRunFinishedDoesNotRewriteCompletedTerminalState() async throws {
        let fixture = try ExecutorFixture()
        defer { fixture.remove() }
        try fixture.createFramework("Foo.framework")

        let rawRunner = RecordingRawDumpRunner()
        let progress = ProgressEventRecorder()
        let plan = try fixture.makePlan(targetRequest: .query("Foo"))
        let executor = makeGenerationExecutor(
            rawDumpRunner: { invocation in try await rawRunner.run(invocation) },
            runIDGenerator: { "run-001" },
            dateProvider: fixedDates()
        )
        let task = Task {
            try await executor.run(.init(
                plan: plan,
                progressReporter: { event in
                    progress.record(event)
                    guard case .runFinished = event else {
                        return
                    }
                    withUnsafeCurrentTask { task in
                        task?.cancel()
                    }
                }
            ))
        }

        let result = try await task.value

        #expect(result.generatedTargets.map(\.description) == ["framework:Foo.framework"])
        let repository = PrivateHeaderGeneration.RunRepository(plan: plan)
        let run = try #require(try repository.readRun(id: "run-001"))
        let manifest = try #require(try repository.readManifest())
        let terminalEvents = progress.events.filter { event in
            if case .runFinished = event {
                return true
            }
            return false
        }

        #expect(run.status == .completed)
        #expect(run.endedAt != nil)
        #expect(run.targetResults.first?.status == .completed)
        #expect(manifest.latestRunID == "run-001")
        #expect(manifest.targets.first?.status == .completed)
        #expect(terminalEvents == [
            .runFinished(runID: "run-001", status: .completed),
        ])
    }

    @Test func cancellationAfterFirstDurableTargetDoesNotStartOrRecordNextTarget() async throws {
        let fixture = try ExecutorFixture()
        defer { fixture.remove() }
        try fixture.createFramework("Foo.framework")
        try fixture.createFramework("Bar.framework")

        let rawRunner = RecordingRawDumpRunner()
        let plan = try fixture.makePlan(
            targetRequest: .identifiers([
                "framework:Foo.framework",
                "framework:Bar.framework",
            ])
        )
        let executor = makeGenerationExecutor(
            rawDumpRunner: { invocation in try await rawRunner.run(invocation) },
            runIDGenerator: { "run-001" },
            dateProvider: fixedDates()
        )
        let task = Task {
            try await executor.run(.init(
                plan: plan,
                progressReporter: { event in
                    guard case .targetFinished(index: 1, total: 2, displayName: _, status: _) = event else {
                        return
                    }
                    withUnsafeCurrentTask { task in
                        task?.cancel()
                    }
                }
            ))
        }

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }

        #expect(rawRunner.invocations.count == 1)
        #expect(
            fileExists(
                plan.artifactDirectory.appendingPathComponent("Frameworks/Foo/Headers/Generated.h")
            )
        )
        #expect(
            !fileExists(
                plan.artifactDirectory.appendingPathComponent("Frameworks/Bar/Headers/Generated.h")
            )
        )
        let repository = PrivateHeaderGeneration.RunRepository(plan: plan)
        let run = try #require(try repository.readRun(id: "run-001"))
        let manifest = try #require(try repository.readManifest())
        let runTarget = try #require(run.targetResults.first)
        let manifestTarget = try #require(manifest.targets.first)

        #expect(run.status == .interrupted)
        #expect(run.endedAt != nil)
        #expect(run.targetResults.count == 1)
        #expect(runTarget.targetID == "framework:Foo.framework")
        #expect(runTarget.status == .completed)
        #expect(manifest.latestRunID == "run-001")
        #expect(manifest.targets.count == 1)
        #expect(manifestTarget.id == "framework:Foo.framework")
        #expect(manifestTarget.status == .completed)
    }

    @Test func cancellationPersistenceFailureIsNotMaskedAsCancellation() async throws {
        let fixture = try ExecutorFixture()
        defer { fixture.remove() }
        try fixture.createFramework("Foo.framework")

        let rawRunner = RecordingRawDumpRunner()
        let plan = try fixture.makePlan(targetRequest: .query("Foo"))
        let repository = PrivateHeaderGeneration.RunRepository(plan: plan)
        let executor = makeGenerationExecutor(
            rawDumpRunner: { invocation in try await rawRunner.run(invocation) },
            runIDGenerator: { "run-001" },
            dateProvider: fixedDates()
        )
        let task = Task {
            try await executor.run(.init(
                plan: plan,
                progressReporter: { event in
                    guard case .targetStarted = event else {
                        return
                    }
                    do {
                        try FileManager.default.removeItem(at: repository.manifestURL)
                        try FileManager.default.createDirectory(
                            at: repository.manifestURL,
                            withIntermediateDirectories: false
                        )
                    } catch {
                        Issue.record("failed to inject manifest write failure: \(error)")
                    }
                    withUnsafeCurrentTask { task in
                        task?.cancel()
                    }
                }
            ))
        }

        do {
            _ = try await task.value
            Issue.record("cancelled run unexpectedly returned success")
        } catch is CancellationError {
            Issue.record("manifest persistence failure was masked as cancellation")
        } catch {
            #expect((error as NSError).domain == NSCocoaErrorDomain)
        }

        #expect(rawRunner.invocations.isEmpty)
        let run = try #require(try repository.readRun(id: "run-001"))
        #expect(run.status == .running)
        #expect(run.endedAt == nil)
        #expect(run.targetResults.first?.status == .interrupted)
    }

    @Test func rawDumpCancellationAfterOneCompletionPersistsProgressWithoutStartingLaterTarget() async throws {
        let fixture = try ExecutorFixture()
        defer { fixture.remove() }
        try fixture.createFramework("Foo.framework")
        try fixture.createFramework("Bar.framework")
        try fixture.createFramework("Baz.framework")

        let rawRunner = CancellableRawDumpRunner(suspendingInvocationNumber: 2)
        let plan = try fixture.makePlan(
            targetRequest: .identifiers([
                "framework:Foo.framework",
                "framework:Bar.framework",
                "framework:Baz.framework",
            ])
        )
        let executor = makeGenerationExecutor(
            rawDumpRunner: { invocation in try await rawRunner.run(invocation) },
            runIDGenerator: { "run-001" },
            dateProvider: fixedDates()
        )
        let task = Task {
            try await executor.run(.init(plan: plan))
        }
        await rawRunner.waitUntilStarted()

        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }

        #expect(rawRunner.invocations.count == 2)
        #expect(
            fileExists(
                plan.artifactDirectory.appendingPathComponent("Frameworks/Foo/Headers/Generated.h")
            )
        )
        #expect(
            !fileExists(
                plan.artifactDirectory.appendingPathComponent("Frameworks/Bar/Headers/Generated.h")
            )
        )
        #expect(
            !fileExists(
                plan.artifactDirectory.appendingPathComponent("Frameworks/Baz/Headers/Generated.h")
            )
        )

        let repository = PrivateHeaderGeneration.RunRepository(plan: plan)
        let run = try #require(try repository.readRun(id: "run-001"))
        let manifest = try #require(try repository.readManifest())
        let runTargetsByID = Dictionary(
            uniqueKeysWithValues: run.targetResults.map { ($0.targetID, $0) }
        )
        let manifestTargetsByID = Dictionary(
            uniqueKeysWithValues: manifest.targets.map { ($0.id, $0) }
        )
        let completedRunTarget = try #require(runTargetsByID["framework:Foo.framework"])
        let interruptedRunTarget = try #require(runTargetsByID["framework:Bar.framework"])
        let completedManifestTarget = try #require(manifestTargetsByID["framework:Foo.framework"])
        let interruptedManifestTarget = try #require(manifestTargetsByID["framework:Bar.framework"])

        #expect(run.status == .interrupted)
        #expect(run.endedAt != nil)
        #expect(run.targetResults.map(\.targetID) == [
            "framework:Foo.framework",
            "framework:Bar.framework",
        ])
        #expect(completedRunTarget.status == .completed)
        #expect(completedRunTarget.artifacts.map(\.rawValue) == [
            "Frameworks/Foo/Headers/Generated.h",
        ])
        #expect(interruptedRunTarget.status == .interrupted)
        #expect(interruptedRunTarget.phases.isEmpty)
        #expect(interruptedRunTarget.artifacts.isEmpty)
        #expect(interruptedRunTarget.attemptedArtifacts.isEmpty)
        #expect(interruptedRunTarget.failureSummary == "cancelled")
        #expect(manifest.latestRunID == "run-001")
        #expect(Set(manifest.targets.map(\.id)) == [
            "framework:Foo.framework",
            "framework:Bar.framework",
        ])
        #expect(completedManifestTarget.status == .completed)
        #expect(completedManifestTarget.artifacts.map(\.rawValue) == [
            "Frameworks/Foo/Headers/Generated.h",
        ])
        #expect(interruptedManifestTarget.status == .interrupted)
        #expect(interruptedManifestTarget.phases.isEmpty)
        #expect(interruptedManifestTarget.artifacts.isEmpty)
        #expect(interruptedManifestTarget.failureSummary == "cancelled")
    }

    @Test func availableResumeSummaryUsesInventoryAndRejectsChangedCacheCohort() async throws {
        let fixture = try ExecutorFixture()
        defer { fixture.remove() }
        try fixture.createFramework("Foo.framework")
        let previousCacheUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let currentCacheUUID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let plan = try fixture.makePlan(
            targetRequest: .query("Foo"),
            rawDumpingOptions: .init(useSharedCache: true)
        )
        try fixture.writeState(
            plan: plan,
            runID: "run-prev",
            targetID: "framework:Foo.framework",
            status: .partial,
            artifacts: [],
            runStatus: .partial,
            attemptedArtifacts: [],
            cacheUUID: previousCacheUUID
        )
        let inventoryRunner = RecordingSharedCacheInventoryRunner(
            data: try inventoryData(
                cacheUUID: currentCacheUUID,
                imagePaths: ["/System/Library/Frameworks/Foo.framework/Foo"]
            )
        )
        let executor = makeGenerationExecutor(
            sharedCacheInventoryRunner: { invocation in
                try await inventoryRunner.run(invocation)
            }
        )

        let summary = try await executor.availableResumeSummary(for: plan)

        #expect(summary == nil)
        #expect(inventoryRunner.invocations.count == 1)
    }

    @Test func bundleLayoutCommitsArtifactsWithBundleSuffixes() async throws {
        let fixture = try ExecutorFixture()
        defer { fixture.remove() }
        try fixture.createFramework("Foo.framework")

        let runner = RecordingRawDumpRunner()
        let plan = try fixture.makePlan(
            targetRequest: .query("Foo"),
            layout: .bundle
        )
        let executor = makeGenerationExecutor(
            rawDumpRunner: { invocation in try await runner.run(invocation) },
            runIDGenerator: { "run-001" },
            dateProvider: fixedDates()
        )

        let result = try await executor.run(.init(plan: plan))
        let manifest = try PrivateHeaderGeneration.StateJSON.read(
            PrivateHeaderGeneration.Manifest.self,
            from: result.manifestURL
        )

        #expect(fileExists(plan.artifactDirectory.appendingPathComponent("Frameworks/Foo.framework/Headers/Generated.h")))
        #expect(!fileExists(plan.artifactDirectory.appendingPathComponent("Frameworks/Foo/Headers/Generated.h")))
        #expect(manifest.layout == .bundle)
        #expect(manifest.targets.first?.artifacts.map(\.rawValue) == ["Frameworks/Foo.framework/Headers/Generated.h"])
    }

    @Test func headersLayoutKeepsSiblingBundleNamespacesDistinct() async throws {
        let fixture = try ExecutorFixture()
        defer { fixture.remove() }
        try fixture.createSystemBundle("CoreServices/Siri.app")
        try fixture.createSystemBundle("CoreServices/Siri.bundle")

        let runner = RecordingRawDumpRunner()
        let targetIDs = [
            "system-library:CoreServices/Siri.app",
            "system-library:CoreServices/Siri.bundle",
        ]
        let plan = try fixture.makePlan(targetRequest: .identifiers(targetIDs))
        let executor = makeGenerationExecutor(
            rawDumpRunner: { invocation in try await runner.run(invocation) },
            runIDGenerator: { "run-001" },
            dateProvider: fixedDates()
        )

        let result = try await executor.run(.init(plan: plan))

        #expect(runner.invocations.count == 2)
        #expect(result.generatedTargets.map(\.description) == targetIDs)
        #expect(
            fileExists(
                plan.artifactDirectory.appendingPathComponent(
                    "SystemLibrary/CoreServices/Siri.app/Headers/Generated.h"
                )
            )
        )
        #expect(
            fileExists(
                plan.artifactDirectory.appendingPathComponent(
                    "SystemLibrary/CoreServices/Siri.bundle/Headers/Generated.h"
                )
            )
        )

        let manifest = try PrivateHeaderGeneration.StateJSON.read(
            PrivateHeaderGeneration.Manifest.self,
            from: result.manifestURL
        )
        #expect(manifest.targets.map(\.id) == targetIDs)
        #expect(manifest.targets.map(\.status) == [.completed, .completed])
    }

    @Test func partialTargetRerunsWithoutDeletingOldCommittedArtifactsWhenGenerationFails() async throws {
        let fixture = try ExecutorFixture()
        defer { fixture.remove() }
        try fixture.createFramework("Foo.framework")

        let targetID = "framework:Foo.framework"
        let artifact = try PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo/Headers/Generated.h")
        let plan = try fixture.makePlan(
            targetRequest: .query("Foo"),
            resumeBehavior: .resume
        )
        try writeFile(
            "old",
            to: plan.artifactDirectory.appendingPathComponent(artifact.rawValue)
        )
        try fixture.writeState(
            plan: plan,
            runID: "run-prev",
            targetID: targetID,
            status: .partial,
            artifacts: [artifact],
            runStatus: .partial,
            attemptedArtifacts: []
        )

        let runner = RecordingRawDumpRunner(
            result: PrivateHeaderGeneration.RawDumping.Result(
                terminationStatus: 1,
                failureSummary: "simulated raw failure"
            ),
            writesArtifacts: false
        )
        let executor = makeGenerationExecutor(
            rawDumpRunner: { invocation in try await runner.run(invocation) },
            runIDGenerator: { "run-002" },
            dateProvider: fixedDates()
        )

        await #expect(throws: PrivateHeaderGeneration.GenerationError.self) {
            _ = try await executor.run(.init(plan: plan))
        }

        let finalText = try String(
            contentsOf: plan.artifactDirectory.appendingPathComponent(artifact.rawValue),
            encoding: .utf8
        )
        let manifest = try PrivateHeaderGeneration.StateJSON.read(
            PrivateHeaderGeneration.Manifest.self,
            from: plan.stateDirectory.appendingPathComponent("manifest.json")
        )
        let run = try PrivateHeaderGeneration.StateJSON.read(
            PrivateHeaderGeneration.RunRecord.self,
            from: plan.stateDirectory.appendingPathComponent("runs/run-002/run.json")
        )

        #expect(finalText == "old")
        #expect(manifest.targets.first?.status == .failed)
        #expect(manifest.targets.first?.artifacts == [artifact])
        #expect(run.targetResults.first?.status == .failed)
        #expect(run.targetResults.first?.attemptedArtifacts.isEmpty == true)
    }

    @Test func rawDumpFailureCommitsStagedArtifactsAsPartial() async throws {
        let fixture = try ExecutorFixture()
        defer { fixture.remove() }
        try fixture.createFramework("Foo.framework")

        let runner = RecordingRawDumpRunner(
            result: PrivateHeaderGeneration.RawDumping.Result(
                terminationStatus: 1,
                failureSummary: "Swift interface generation failed"
            )
        )
        let plan = try fixture.makePlan(targetRequest: .query("Foo"))
        let executor = makeGenerationExecutor(
            rawDumpRunner: { invocation in try await runner.run(invocation) },
            runIDGenerator: { "run-001" },
            dateProvider: fixedDates()
        )

        await #expect(throws: PrivateHeaderGeneration.GenerationError.self) {
            _ = try await executor.run(.init(plan: plan))
        }

        let artifact = try PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo/Headers/Generated.h")
        let manifest = try PrivateHeaderGeneration.StateJSON.read(
            PrivateHeaderGeneration.Manifest.self,
            from: plan.stateDirectory.appendingPathComponent("manifest.json")
        )
        let run = try PrivateHeaderGeneration.StateJSON.read(
            PrivateHeaderGeneration.RunRecord.self,
            from: plan.stateDirectory.appendingPathComponent("runs/run-001/run.json")
        )
        let manifestTarget = try #require(manifest.targets.first)
        let runTarget = try #require(run.targetResults.first)

        #expect(fileExists(plan.artifactDirectory.appendingPathComponent(artifact.rawValue)))
        #expect(manifestTarget.status == .partial)
        #expect(manifestTarget.artifacts == [artifact])
        #expect(manifestTarget.failureSummary == "Swift interface generation failed")
        #expect(run.status == .partial)
        #expect(run.attemptedArtifacts == [artifact])
        #expect(runTarget.status == .partial)
        #expect(runTarget.phases.map(\.name) == ["raw-header-dump", "commit"])
        #expect(runTarget.phases.map(\.status) == [.failed, .completed])
        #expect(runTarget.artifacts == [artifact])
        #expect(runTarget.attemptedArtifacts == [artifact])
        #expect(runTarget.failureSummary == "Swift interface generation failed")
    }

    @Test func commitFailedResumeCleansManagedAndAttemptedArtifactsBeforeRerun() async throws {
        let fixture = try ExecutorFixture()
        defer { fixture.remove() }
        try fixture.createFramework("Foo.framework")

        let targetID = "framework:Foo.framework"
        let managed = try PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo/Headers/Old.h")
        let attempted = try PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo/Headers/Leftover.h")
        let plan = try fixture.makePlan(
            targetRequest: .query("Foo"),
            resumeBehavior: .resume
        )
        try writeFile("managed", to: plan.artifactDirectory.appendingPathComponent(managed.rawValue))
        try writeFile("attempted", to: plan.artifactDirectory.appendingPathComponent(attempted.rawValue))
        try fixture.writeState(
            plan: plan,
            runID: "run-prev",
            targetID: targetID,
            status: .commitFailed,
            artifacts: [managed],
            runStatus: .commitFailed,
            attemptedArtifacts: [attempted]
        )

        let runner = RecordingRawDumpRunner()
        let executor = makeGenerationExecutor(
            rawDumpRunner: { invocation in try await runner.run(invocation) },
            runIDGenerator: { "run-002" },
            dateProvider: fixedDates()
        )

        _ = try await executor.run(.init(plan: plan))

        #expect(!fileExists(plan.artifactDirectory.appendingPathComponent(managed.rawValue)))
        #expect(!fileExists(plan.artifactDirectory.appendingPathComponent(attempted.rawValue)))
        #expect(fileExists(plan.artifactDirectory.appendingPathComponent("Frameworks/Foo/Headers/Generated.h")))
    }

    @Test func unsafeCommitDestinationDoesNotCleanupPreservedArtifacts() async throws {
        let fixture = try ExecutorFixture()
        defer { fixture.remove() }
        try fixture.createFramework("Foo.framework")

        let targetID = "framework:Foo.framework"
        let managed = try PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo/Headers/Old.h")
        let plan = try fixture.makePlan(
            targetRequest: .query("Foo"),
            resumeBehavior: .resume
        )
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        let externalFile = outside.appendingPathComponent("External.h")
        let unsafeDestination = plan.artifactDirectory
            .appendingPathComponent("Frameworks/Foo/Headers/Generated.h")
        try writeFile("managed", to: plan.artifactDirectory.appendingPathComponent(managed.rawValue))
        try writeFile("external", to: externalFile)
        try FileManager.default.createSymbolicLink(
            at: unsafeDestination,
            withDestinationURL: externalFile
        )
        try fixture.writeState(
            plan: plan,
            runID: "run-prev",
            targetID: targetID,
            status: .partial,
            artifacts: [managed],
            runStatus: .partial,
            attemptedArtifacts: [managed]
        )

        let runner = RecordingRawDumpRunner()
        let executor = makeGenerationExecutor(
            rawDumpRunner: { invocation in try await runner.run(invocation) },
            runIDGenerator: { "run-002" },
            dateProvider: fixedDates()
        )

        await #expect(throws: PrivateHeaderGeneration.GenerationError.self) {
            _ = try await executor.run(.init(plan: plan))
        }

        #expect(
            try String(
                contentsOf: plan.artifactDirectory.appendingPathComponent(managed.rawValue),
                encoding: .utf8
            )
                == "managed"
        )
        #expect(try String(contentsOf: externalFile, encoding: .utf8) == "external")
        let attributes = try FileManager.default.attributesOfItem(atPath: unsafeDestination.path)
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)

        let manifest = try PrivateHeaderGeneration.StateJSON.read(
            PrivateHeaderGeneration.Manifest.self,
            from: plan.stateDirectory.appendingPathComponent("manifest.json")
        )
        let run = try PrivateHeaderGeneration.StateJSON.read(
            PrivateHeaderGeneration.RunRecord.self,
            from: plan.stateDirectory.appendingPathComponent("runs/run-002/run.json")
        )
        #expect(manifest.targets.first?.artifacts == [managed])
        #expect(run.targetResults.first?.status == .commitFailed)
        #expect(run.targetResults.first?.artifacts.isEmpty == true)
        #expect(run.targetResults.first?.phases.map(\.name) == ["raw-header-dump", "commit"])
    }

    @Test func simulatorExecutionUsesRuntimeInputPathAndCommitsHeaderAndSwiftInterfaceArtifacts() async throws {
        let fixture = try ExecutorFixture()
        defer { fixture.remove() }
        try fixture.createFramework("Foo.framework")

        let runner = RecordingRawDumpRunner()
        let inventoryRunner = RecordingSharedCacheInventoryRunner(
            data: try inventoryData(imagePaths: [
                "/System/Library/Frameworks/Foo.framework/Foo",
            ])
        )
        let plan = try fixture.makePlan(
            targetRequest: .query("Foo"),
            executionMode: .simulator(deviceUDID: "SIM-001", runtimeRoot: fixture.systemRoot.path),
            rawDumpingOptions: PrivateHeaderGeneration.RawDumping.Options(
                useSharedCache: true,
                helperEnvironment: ["SIMCTL_CHILD_PH_PROFILE": "1"]
            )
        )
        let executor = makeGenerationExecutor(
            rawDumpRunner: { invocation in try await runner.run(invocation) },
            sharedCacheInventoryRunner: { invocation in
                try await inventoryRunner.run(invocation)
            },
            runIDGenerator: { "run-001" },
            dateProvider: fixedDates()
        )

        let result = try await executor.run(.init(plan: plan))

        let invocation = try #require(runner.invocations.first)
        #expect(runner.invocations.count == 1)
        #expect(invocation.phaseLabel == "raw-header-dump")
        #expect(invocation.inputPath == "/System/Library/Frameworks/Foo.framework")
        #expect(Array(invocation.command.prefix(4)) == ["xcrun", "simctl", "spawn", "SIM-001"])
        #expect(invocation.command.contains(fixture.helperURLs.simulator.path))
        #expect(invocation.environment["SIMCTL_CHILD_PH_RUNTIME_ROOT"] == fixture.systemRoot.path)
        #expect(invocation.environment["SIMCTL_CHILD_DYLD_ROOT_PATH"] == fixture.systemRoot.path)
        #expect(invocation.environment["SIMCTL_CHILD_PH_PROFILE"] == "1")

        let expectedArtifacts = [
            "Frameworks/Foo/Headers/Foo.swiftinterface",
            "Frameworks/Foo/Headers/Generated.h",
        ]
        #expect(fileExists(plan.artifactDirectory.appendingPathComponent("Frameworks/Foo/Headers/Generated.h")))
        #expect(fileExists(plan.artifactDirectory.appendingPathComponent("Frameworks/Foo/Headers/Foo.swiftinterface")))

        let manifest = try PrivateHeaderGeneration.StateJSON.read(
            PrivateHeaderGeneration.Manifest.self,
            from: result.manifestURL
        )
        let run = try PrivateHeaderGeneration.StateJSON.read(
            PrivateHeaderGeneration.RunRecord.self,
            from: result.runRecordURL
        )
        #expect(manifest.targets.first?.artifacts.map(\.rawValue) == expectedArtifacts)
        #expect(run.targetResults.first?.attemptedArtifacts.map(\.rawValue) == expectedArtifacts)
    }

    @Test func simulatorExecutionCompletesWhenRawDumpProducesHeaderOnlyArtifacts() async throws {
        let fixture = try ExecutorFixture()
        defer { fixture.remove() }
        try fixture.createFramework("Foo.framework")

        let runner = RecordingRawDumpRunner(
            writesSwiftInterfaceForSimulator: false
        )
        let inventoryRunner = RecordingSharedCacheInventoryRunner(
            data: try inventoryData(imagePaths: [
                "/System/Library/Frameworks/Foo.framework/Foo",
            ])
        )
        let plan = try fixture.makePlan(
            targetRequest: .query("Foo"),
            executionMode: .simulator(deviceUDID: "SIM-001", runtimeRoot: fixture.systemRoot.path),
            rawDumpingOptions: PrivateHeaderGeneration.RawDumping.Options(useSharedCache: true)
        )
        let executor = makeGenerationExecutor(
            rawDumpRunner: { invocation in try await runner.run(invocation) },
            sharedCacheInventoryRunner: { invocation in
                try await inventoryRunner.run(invocation)
            },
            runIDGenerator: { "run-001" },
            dateProvider: fixedDates()
        )

        let result = try await executor.run(.init(plan: plan))

        let manifest = try PrivateHeaderGeneration.StateJSON.read(
            PrivateHeaderGeneration.Manifest.self,
            from: result.manifestURL
        )
        let run = try PrivateHeaderGeneration.StateJSON.read(
            PrivateHeaderGeneration.RunRecord.self,
            from: result.runRecordURL
        )
        let target = try #require(run.targetResults.first)
        #expect(runner.invocations.map(\.phaseLabel) == ["raw-header-dump"])
        #expect(target.status == .completed)
        #expect(target.phases.map(\.name) == ["raw-header-dump", "commit"])
        #expect(target.phases.map(\.status) == [.completed, .completed])
        #expect(target.failureSummary == nil)
        #expect(manifest.targets.first?.artifacts.map(\.rawValue) == [
            "Frameworks/Foo/Headers/Generated.h",
        ])
        #expect(target.attemptedArtifacts.map(\.rawValue) == [
            "Frameworks/Foo/Headers/Generated.h",
        ])
    }
}

private final class StateLockProbe: @unchecked Sendable {
    let repository: PrivateHeaderGeneration.RunRepository
    var unavailablePath: String?
    var unexpectedlyAcquired = false
    var unexpectedError: String?

    init(repository: PrivateHeaderGeneration.RunRepository) {
        self.repository = repository
    }

    func recordNestedLockAttempt() async {
        do {
            try await repository.withExclusiveLock(wait: false) {
                unexpectedlyAcquired = true
            }
        } catch let error as PrivateHeaderGeneration.RunRepositoryError {
            switch error {
            case .lockUnavailable(let path):
                unavailablePath = path
            default:
                unexpectedError = String(describing: error)
            }
        } catch {
            unexpectedError = String(describing: error)
        }
    }
}

private final class RecordingRawDumpRunner: @unchecked Sendable {
    var invocations: [PrivateHeaderGeneration.RawDumping.Invocation] = []
    var result: PrivateHeaderGeneration.RawDumping.Result
    var writesArtifacts: Bool
    var writesSwiftInterfaceForSimulator: Bool

    init(
        result: PrivateHeaderGeneration.RawDumping.Result = PrivateHeaderGeneration.RawDumping.Result(terminationStatus: 0),
        writesArtifacts: Bool = true,
        writesSwiftInterfaceForSimulator: Bool = true
    ) {
        self.result = result
        self.writesArtifacts = writesArtifacts
        self.writesSwiftInterfaceForSimulator = writesSwiftInterfaceForSimulator
    }

    func run(
        _ invocation: PrivateHeaderGeneration.RawDumping.Invocation
    ) async throws -> PrivateHeaderGeneration.RawDumping.Result {
        invocations.append(invocation)
        if writesArtifacts {
            let outputDirectory = outputDirectory(
                stagingDirectory: invocation.stagingOutputDirectory,
                inputPath: invocation.inputPath
            )
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
            try Data("// generated\n".utf8)
                .write(to: outputDirectory.appendingPathComponent("Generated.h"))
            if case .simulator = invocation.executionMode, writesSwiftInterfaceForSimulator {
                try Data("// generated\n".utf8)
                    .write(to: outputDirectory.appendingPathComponent("Foo.swiftinterface"))
            }
        }
        return result
    }

    private func outputDirectory(stagingDirectory: URL, inputPath: String) -> URL {
        if let range = inputPath.range(of: "/System/Library/") {
            return appendRelativePath(
                String(inputPath[range.lowerBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                to: stagingDirectory
            )
            .appendingPathComponent("Headers", isDirectory: true)
        }
        if let range = inputPath.range(of: "/usr/lib/") {
            return appendRelativePath(
                String(inputPath[range.lowerBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                to: stagingDirectory
            )
            .appendingPathComponent("Headers", isDirectory: true)
        }
        return stagingDirectory.appendingPathComponent("Headers", isDirectory: true)
    }
}

private final class CancellableRawDumpRunner: @unchecked Sendable {
    typealias Result = PrivateHeaderGeneration.RawDumping.Result

    private let lock = NSLock()
    private let startedStream: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation
    private var recordedInvocations: [PrivateHeaderGeneration.RawDumping.Invocation] = []
    private var resultContinuation: CheckedContinuation<Result, any Error>?
    private var cancellationRequested = false
    private let suspendingInvocationNumber: Int

    init(suspendingInvocationNumber: Int = 1) {
        precondition(suspendingInvocationNumber > 0)
        self.suspendingInvocationNumber = suspendingInvocationNumber
        let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        startedStream = started.stream
        startedContinuation = started.continuation
    }

    var invocations: [PrivateHeaderGeneration.RawDumping.Invocation] {
        lock.withLock { recordedInvocations }
    }

    func waitUntilStarted() async {
        for await _ in startedStream {
            return
        }
    }

    func run(
        _ invocation: PrivateHeaderGeneration.RawDumping.Invocation
    ) async throws -> Result {
        try writeStagedArtifact(for: invocation)
        let invocationNumber = lock.withLock {
            recordedInvocations.append(invocation)
            return recordedInvocations.count
        }
        if invocationNumber < suspendingInvocationNumber {
            return Result(terminationStatus: 0)
        }
        precondition(invocationNumber == suspendingInvocationNumber)
        startedContinuation.yield()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let wasAlreadyCancelled = lock.withLock {
                    if cancellationRequested {
                        return true
                    }
                    precondition(resultContinuation == nil)
                    resultContinuation = continuation
                    return false
                }
                if wasAlreadyCancelled {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func cancel() {
        let continuation = lock.withLock {
            cancellationRequested = true
            defer { resultContinuation = nil }
            return resultContinuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    private func writeStagedArtifact(
        for invocation: PrivateHeaderGeneration.RawDumping.Invocation
    ) throws {
        let marker = "/System/Library/"
        let range = try #require(invocation.inputPath.range(of: marker))
        let relativePath = String(invocation.inputPath[range.upperBound...])
        let outputDirectory = appendRelativePath(
            relativePath,
            to: invocation.stagingOutputDirectory
                .appendingPathComponent("System", isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
        )
        .appendingPathComponent("Headers", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        try Data("// generated\n".utf8)
            .write(to: outputDirectory.appendingPathComponent("Generated.h"))
    }
}

private final class RecordingSharedCacheInventoryRunner: @unchecked Sendable {
    private let lock = NSLock()
    private let data: Data
    private var recordedInvocations: [PrivateHeaderGeneration.RawDumping.SharedCacheInventoryInvocation] = []

    init(data: Data) {
        self.data = data
    }

    var invocations: [PrivateHeaderGeneration.RawDumping.SharedCacheInventoryInvocation] {
        lock.withLock { recordedInvocations }
    }

    func run(
        _ invocation: PrivateHeaderGeneration.RawDumping.SharedCacheInventoryInvocation
    ) async throws -> Data {
        lock.withLock {
            recordedInvocations.append(invocation)
        }
        return data
    }
}

private enum InventoryTestError: Error {
    case failed
}

private struct ExecutorFixture {
    let root: URL
    let systemRoot: URL
    let outputBase: URL
    let helperURLs: PrivateHeaderGeneration.RawDumping.HelperURLs

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateHeaderGenerationExecutorTests-\(UUID().uuidString)", isDirectory: true)
        systemRoot = root.appendingPathComponent("RuntimeRoot", isDirectory: true)
        outputBase = root.appendingPathComponent("Output", isDirectory: true)
        let helperURL = root.appendingPathComponent("bin/privateheaderkit")
        let simulatorHelperURL = root.appendingPathComponent("libexec/privateheaderkit/privateheaderkit-sim-helper")
        helperURLs = PrivateHeaderGeneration.RawDumping.HelperURLs(
            host: helperURL,
            simulator: simulatorHelperURL
        )
        try FileManager.default.createDirectory(at: systemRoot, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func createFramework(_ name: String) throws {
        try FileManager.default.createDirectory(
            at: systemRoot.appendingPathComponent("System/Library/Frameworks/\(name)", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    func createSystemBundle(_ relativePath: String) throws {
        try FileManager.default.createDirectory(
            at: systemRoot.appendingPathComponent(
                "System/Library/\(relativePath)",
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )
    }

    func makePlan(
        targetRequest: PrivateHeaderGeneration.TargetRequest,
        layout: PrivateHeaderGeneration.Layout = .headers,
        resumeBehavior: PrivateHeaderGeneration.ResumeBehavior = .requireExplicitResume(resumeRequested: false),
        executionMode: PrivateHeaderGeneration.RawDumping.ExecutionMode = .host,
        rawDumpingOptions: PrivateHeaderGeneration.RawDumping.Options = PrivateHeaderGeneration.RawDumping.Options()
    ) throws -> PrivateHeaderGeneration.Plan {
        let source = try PrivateHeaderGeneration.Source(
            platform: .macOS,
            version: "16.0",
            build: "25A000"
        )
        let output = PrivateHeaderGeneration.Output(baseDirectory: outputBase)
        return PrivateHeaderGeneration.makePlan(
            source: source,
            output: output,
            options: PrivateHeaderGeneration.Options(
                layout: layout,
                targetRequest: targetRequest,
                systemRoot: systemRoot,
                helperURLs: helperURLs,
                executionMode: executionMode,
                rawDumpingOptions: rawDumpingOptions,
                resumeBehavior: resumeBehavior,
                outputBaseDirectory: outputBase
            )
        )
    }

    func writeState(
        plan: PrivateHeaderGeneration.Plan,
        runID: String,
        targetID: String,
        status: PrivateHeaderGeneration.TargetStatus,
        artifacts: [PrivateHeaderGeneration.ArtifactPath],
        runStatus: PrivateHeaderGeneration.RunTargetStatus,
        attemptedArtifacts: [PrivateHeaderGeneration.ArtifactPath],
        cacheUUID: UUID? = nil
    ) throws {
        let repository = PrivateHeaderGeneration.RunRepository(plan: plan)
        let runPlan = makeRunPlan(
            plan: plan,
            targetIDs: [targetID],
            cacheUUID: cacheUUID
        )
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let target = PrivateHeaderGeneration.TargetRecord(
            id: targetID,
            displayName: "Foo",
            kind: "framework",
            status: status,
            phases: [
                PrivateHeaderGeneration.PhaseRecord(name: "raw-header-dump", status: .failed),
            ],
            artifacts: artifacts,
            lastRunID: runID,
            updatedAt: now,
            failureSummary: status == .completed ? nil : status.rawValue
        )
        let manifest = PrivateHeaderGeneration.Manifest(
            schemaVersion: 1,
            toolVersion: "0.1.0",
            source: runPlan.source,
            output: runPlan.output,
            layout: plan.options.layout,
            latestRunID: runID,
            targets: [target],
            updatedAt: now
        )
        let run = PrivateHeaderGeneration.RunRecord(
            runID: runID,
            schemaVersion: 1,
            toolVersion: "0.1.0",
            plan: runPlan,
            startedAt: now,
            endedAt: now,
            status: runStatus,
            targetResults: [
                PrivateHeaderGeneration.RunTargetRecord(
                    targetID: targetID,
                    status: runStatus,
                    phases: target.phases,
                    artifacts: artifacts,
                    attemptedArtifacts: attemptedArtifacts,
                    failureSummary: runStatus == .completed ? nil : runStatus.rawValue
                ),
            ],
            attemptedArtifacts: attemptedArtifacts,
            logs: []
        )

        try repository.writeManifest(manifest)
        try repository.writeRun(run)
    }

    private func makeRunPlan(
        plan: PrivateHeaderGeneration.Plan,
        targetIDs: [String],
        cacheUUID: UUID?
    ) -> PrivateHeaderGeneration.RunPlanRecord {
        PrivateHeaderGeneration.RunPlanRecord(
            source: PrivateHeaderGeneration.SourceRecord(source: plan.source),
            output: PrivateHeaderGeneration.OutputRecord(
                plan: plan,
                baseDirectory: outputBase
            ),
            layout: plan.options.layout,
            targetIDs: targetIDs,
            execution: PrivateHeaderGeneration.ExecutionRecord(
                mode: "host",
                runtimeIdentifier: nil,
                deviceName: nil,
                deviceUDID: nil,
                clonePolicy: nil,
                cacheUUID: cacheUUID,
                helperEnvironment: [:]
            )
        )
    }
}

private enum UnexpectedGenerationRunnerInvocation: Error {
    case rawDump
    case sharedCacheInventory
}

private func makeGenerationExecutor(
    rawDumpRunner: @escaping PrivateHeaderGeneration.GenerationExecutor.RawDumpRunner = { _ in
        throw UnexpectedGenerationRunnerInvocation.rawDump
    },
    sharedCacheInventoryRunner: @escaping PrivateHeaderGeneration.GenerationExecutor.SharedCacheInventoryRunner = { _ in
        throw UnexpectedGenerationRunnerInvocation.sharedCacheInventory
    },
    runIDGenerator: @escaping @Sendable () -> String = { "run-test" },
    dateProvider: @escaping @Sendable () -> Date = {
        Date(timeIntervalSinceReferenceDate: 0)
    }
) -> PrivateHeaderGeneration.GenerationExecutor {
    PrivateHeaderGeneration.GenerationExecutor(
        rawDumpRunner: rawDumpRunner,
        sharedCacheInventoryRunner: sharedCacheInventoryRunner,
        runIDGenerator: runIDGenerator,
        dateProvider: dateProvider
    )
}

private func fixedDates() -> @Sendable () -> Date {
    final class Counter: @unchecked Sendable {
        var value = 0
    }
    let counter = Counter()
    return {
        defer { counter.value += 1 }
        return Date(timeIntervalSinceReferenceDate: TimeInterval(counter.value))
    }
}

private func inventoryData(
    cacheUUID: UUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
    imagePaths: [String]
) throws -> Data {
    try JSONEncoder().encode(
        PrivateHeaderKitSharedCacheInventory(
            cacheUUID: cacheUUID,
            imagePaths: imagePaths
        )
    )
}

private final class ProgressEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [PrivateHeaderGeneration.ProgressEvent] = []

    var events: [PrivateHeaderGeneration.ProgressEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    func record(_ event: PrivateHeaderGeneration.ProgressEvent) {
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }
}

private func appendRelativePath(_ relativePath: String, to base: URL) -> URL {
    var url = base
    for component in relativePath.split(separator: "/", omittingEmptySubsequences: false) {
        url.appendPathComponent(String(component), isDirectory: true)
    }
    return url
}

private func writeFile(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try text.write(to: url, atomically: true, encoding: .utf8)
}

private func fileExists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}
