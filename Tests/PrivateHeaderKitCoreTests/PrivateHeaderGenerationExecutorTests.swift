import Foundation
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
        let executor = PrivateHeaderGeneration.GenerationExecutor(
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

    @Test func completedTargetWithManagedArtifactsIsSkippedOnResume() async throws {
        let fixture = try ExecutorFixture()
        defer { fixture.remove() }
        try fixture.createFramework("Foo.framework")

        let firstRunner = RecordingRawDumpRunner()
        let plan = try fixture.makePlan(targetRequest: .query("Foo"))
        let firstExecutor = PrivateHeaderGeneration.GenerationExecutor(
            rawDumpRunner: { invocation in try await firstRunner.run(invocation) },
            runIDGenerator: { "run-001" },
            dateProvider: fixedDates()
        )
        _ = try await firstExecutor.run(.init(plan: plan))

        let secondRunner = RecordingRawDumpRunner()
        let secondExecutor = PrivateHeaderGeneration.GenerationExecutor(
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
        let executor = PrivateHeaderGeneration.GenerationExecutor(
            rawDumpRunner: { invocation in try await runner.run(invocation) },
            runIDGenerator: { "run-002" },
            dateProvider: fixedDates()
        )

        await #expect(throws: PrivateHeaderGeneration.GenerationError.self) {
            _ = try await executor.run(.init(plan: plan))
        }
        #expect(runner.invocations.isEmpty)
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
        let executor = PrivateHeaderGeneration.GenerationExecutor(
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
        let executor = PrivateHeaderGeneration.GenerationExecutor(
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
        let executor = PrivateHeaderGeneration.GenerationExecutor(
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
        let executor = PrivateHeaderGeneration.GenerationExecutor(
            rawDumpRunner: { invocation in try await runner.run(invocation) },
            runIDGenerator: { "run-002" },
            dateProvider: fixedDates()
        )

        _ = try await executor.run(.init(plan: plan))

        #expect(!fileExists(plan.artifactDirectory.appendingPathComponent(managed.rawValue)))
        #expect(!fileExists(plan.artifactDirectory.appendingPathComponent(attempted.rawValue)))
        #expect(fileExists(plan.artifactDirectory.appendingPathComponent("Frameworks/Foo/Headers/Generated.h")))
    }

    @Test func simulatorExecutionUsesRuntimeInputPathAndCommitsHeaderAndSwiftInterfaceArtifacts() async throws {
        let fixture = try ExecutorFixture()
        defer { fixture.remove() }
        try fixture.createFramework("Foo.framework")

        let runner = RecordingRawDumpRunner()
        let plan = try fixture.makePlan(
            targetRequest: .query("Foo"),
            executionMode: .simulator(deviceUDID: "SIM-001", runtimeRoot: fixture.systemRoot.path),
            rawDumpingOptions: PrivateHeaderGeneration.RawDumping.Options(
                useSharedCache: true,
                helperEnvironment: ["SIMCTL_CHILD_PH_PROFILE": "1"]
            )
        )
        let executor = PrivateHeaderGeneration.GenerationExecutor(
            rawDumpRunner: { invocation in try await runner.run(invocation) },
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
        let plan = try fixture.makePlan(
            targetRequest: .query("Foo"),
            executionMode: .simulator(deviceUDID: "SIM-001", runtimeRoot: fixture.systemRoot.path),
            rawDumpingOptions: PrivateHeaderGeneration.RawDumping.Options(useSharedCache: true)
        )
        let executor = PrivateHeaderGeneration.GenerationExecutor(
            rawDumpRunner: { invocation in try await runner.run(invocation) },
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
        attemptedArtifacts: [PrivateHeaderGeneration.ArtifactPath]
    ) throws {
        let repository = PrivateHeaderGeneration.RunRepository(plan: plan)
        let runPlan = makeRunPlan(plan: plan, targetIDs: [targetID])
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
        targetIDs: [String]
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
                helperEnvironment: [:]
            )
        )
    }
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
