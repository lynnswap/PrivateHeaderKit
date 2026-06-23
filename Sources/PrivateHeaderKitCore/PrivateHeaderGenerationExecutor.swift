import Foundation

public extension PrivateHeaderGeneration {
    static func availableResumeSummary(
        source: Source,
        output: Output,
        options: Options = Options()
    ) throws -> ResumeSummary? {
        let plan = makePlan(
            source: source,
            output: output,
            options: options
        )
        return try GenerationExecutor.availableResumeSummary(for: plan)
    }
}

extension PrivateHeaderGeneration.GenerationExecutor {
    static func availableResumeSummary(
        for plan: PrivateHeaderGeneration.Plan
    ) throws -> PrivateHeaderGeneration.ResumeSummary? {
        let options = plan.options

        guard let systemRoot = options.systemRoot else {
            throw PrivateHeaderGeneration.GenerationError.missingExecutionConfiguration("systemRoot")
        }
        guard let executionMode = options.executionMode else {
            throw PrivateHeaderGeneration.GenerationError.missingExecutionConfiguration("executionMode")
        }

        let catalog = try PrivateHeaderGeneration.TargetDiscovery.discover(
            in: systemRoot,
            includeNestedChildren: options.includeNestedChildren
        )
        let selectedTargets = try Self.selectedExecutionTargets(
            request: options.targetRequest,
            catalog: catalog
        )
        guard !selectedTargets.isEmpty else {
            throw PrivateHeaderGeneration.GenerationError.noDiscoveredTargets(systemRoot: systemRoot.path)
        }

        let repository = PrivateHeaderGeneration.RunRepository(plan: plan)
        guard let manifest = try repository.readManifest() else {
            return nil
        }

        let latestRun = try repository.readLatestRun(from: manifest)
        let runPlan = Self.runPlanRecord(
            plan: plan,
            selectedTargets: selectedTargets,
            executionMode: executionMode,
            helperEnvironment: options.rawDumpingOptions.recordedHelperEnvironment(
                for: executionMode
            )
        )
        let compatibility = PrivateHeaderGeneration.evaluateResumeCompatibility(
            plan: runPlan,
            manifest: manifest,
            latestRun: latestRun
        )
        guard compatibility.isCompatible else {
            return nil
        }

        let artifactStore = PrivateHeaderGeneration.ArtifactStore(
            artifactRoot: plan.artifactDirectory
        )
        let artifactExists: PrivateHeaderGeneration.ArtifactExistence = { artifact in
            (try? artifactStore.contains(artifact)) == true
        }
        let summary = PrivateHeaderGeneration.makeResumeSummary(
            plan: runPlan,
            manifest: manifest,
            latestRun: latestRun,
            artifactExists: artifactExists
        )
        return summary.isUnfinished ? summary : nil
    }
}

public extension PrivateHeaderGeneration {
    struct GenerationExecutor: Sendable {
        public typealias RawDumpRunner = @Sendable (
            PrivateHeaderGeneration.RawDumping.Invocation
        ) async throws -> PrivateHeaderGeneration.RawDumping.Result
        public typealias ProgressReporter = @Sendable (
            PrivateHeaderGeneration.ProgressEvent
        ) -> Void

        public struct Configuration: Sendable {
            public let plan: Plan
            public let progressReporter: ProgressReporter?

            public init(
                plan: Plan,
                progressReporter: ProgressReporter? = nil
            ) {
                self.plan = plan
                self.progressReporter = progressReporter
            }
        }

        public let rawDumpRunner: RawDumpRunner
        private let runIDGenerator: @Sendable () -> String
        private let dateProvider: @Sendable () -> Date

        public init(
            rawDumpRunner: @escaping RawDumpRunner = GenerationExecutor.liveRawDumpRunner,
            runIDGenerator: @escaping @Sendable () -> String = {
                "run-\(UUID().uuidString.lowercased())"
            },
            dateProvider: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.rawDumpRunner = rawDumpRunner
            self.runIDGenerator = runIDGenerator
            self.dateProvider = dateProvider
        }

        public func run(_ configuration: Configuration) async throws -> Result {
            let plan = configuration.plan
            let options = plan.options

            guard let systemRoot = options.systemRoot else {
                throw GenerationError.missingExecutionConfiguration("systemRoot")
            }
            guard let helperURLs = options.helperURLs else {
                throw GenerationError.missingExecutionConfiguration("helperURLs")
            }
            guard let executionMode = options.executionMode else {
                throw GenerationError.missingExecutionConfiguration("executionMode")
            }

            let catalog = try TargetDiscovery.discover(
                in: systemRoot,
                includeNestedChildren: options.includeNestedChildren
            )
            let selectedTargets = try Self.selectedExecutionTargets(
                request: options.targetRequest,
                catalog: catalog
            )
            guard !selectedTargets.isEmpty else {
                throw GenerationError.noDiscoveredTargets(systemRoot: systemRoot.path)
            }

            let repository = RunRepository(plan: plan)
            let artifactStore = ArtifactStore(artifactRoot: plan.artifactDirectory)
            return try await repository.withExclusiveLock {
                try await runWithLockedState(
                    plan: plan,
                    options: options,
                    selectedTargets: selectedTargets,
                    repository: repository,
                    artifactStore: artifactStore,
                    helperURLs: helperURLs,
                    executionMode: executionMode,
                    progressReporter: configuration.progressReporter
                )
            }
        }
    }
}

private extension PrivateHeaderGeneration.GenerationExecutor {
    struct TargetExecutionResult {
        let runTarget: PrivateHeaderGeneration.RunTargetRecord
        let manifestTarget: PrivateHeaderGeneration.TargetRecord
    }

    func runWithLockedState(
        plan: PrivateHeaderGeneration.Plan,
        options: PrivateHeaderGeneration.Options,
        selectedTargets: [PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget],
        repository: PrivateHeaderGeneration.RunRepository,
        artifactStore: PrivateHeaderGeneration.ArtifactStore,
        helperURLs: PrivateHeaderGeneration.RawDumping.HelperURLs,
        executionMode: PrivateHeaderGeneration.RawDumping.ExecutionMode,
        progressReporter: PrivateHeaderGeneration.GenerationExecutor.ProgressReporter?
    ) async throws -> PrivateHeaderGeneration.Result {
        let existingManifest = try repository.readManifest()
        let latestRun = try existingManifest.flatMap { try repository.readLatestRun(from: $0) }
        let runPlan = Self.runPlanRecord(
            plan: plan,
            selectedTargets: selectedTargets,
            executionMode: executionMode,
            helperEnvironment: options.rawDumpingOptions.recordedHelperEnvironment(
                for: executionMode
            )
        )

        let resumeSummary = try Self.resumeSummary(
            for: options.resumeBehavior,
            runPlan: runPlan,
            manifest: existingManifest,
            latestRun: latestRun,
            artifactStore: artifactStore
        )
        let targetIDsToRun = Self.targetIDsToRun(
            resumeBehavior: options.resumeBehavior,
            selectedTargets: selectedTargets,
            resumeSummary: resumeSummary
        )
        let targetsToRun = selectedTargets.filter { targetIDsToRun.contains($0.candidate.identifier) }

        try repository.prepareStateDirectory()
        let runID = runIDGenerator()
        let runDirectories = try repository.prepareRunDirectories(for: runID)
        try FileManager.default.createDirectory(
            at: plan.artifactDirectory,
            withIntermediateDirectories: true
        )

        var targetRecords = existingManifest?.targets ?? []
        if case .fresh = options.resumeBehavior {
            targetRecords = targetRecords.filter { record in
                !selectedTargets.contains { $0.candidate.identifier == record.id }
            }
        }

        let startedAt = dateProvider()
        var runRecord = PrivateHeaderGeneration.RunRecord(
            runID: runID,
            schemaVersion: 1,
            toolVersion: options.toolVersion,
            plan: runPlan,
            startedAt: startedAt,
            endedAt: nil,
            status: .running,
            targetResults: [],
            attemptedArtifacts: [],
            logs: []
        )
        try repository.writeRun(runRecord)
        try repository.writeManifest(
            Self.manifest(
                plan: plan,
                runPlan: runPlan,
                runID: runID,
                targetRecords: targetRecords,
                updatedAt: startedAt
            )
        )
        progressReporter?(.runStarted(
            runID: runID,
            totalTargetCount: targetsToRun.count
        ))

        let previousTargetRecords = Self.targetsByID(existingManifest?.targets ?? [])
        let previousCommitFailedAttempts = Self.commitFailedAttemptedArtifactsByTargetID(latestRun)
        var generatedTargetIDs: [String] = []

        for (offset, target) in targetsToRun.enumerated() {
            let targetIndex = offset + 1
            progressReporter?(.targetStarted(
                index: targetIndex,
                total: targetsToRun.count,
                displayName: target.candidate.displayName
            ))
            let targetResult = try await executeTarget(
                target,
                runID: runID,
                runDirectories: runDirectories,
                plan: plan,
                helperURLs: helperURLs,
                executionMode: executionMode,
                rawDumpingOptions: options.rawDumpingOptions,
                artifactStore: artifactStore,
                previousTarget: previousTargetRecords[target.candidate.identifier],
                previousCommitFailedAttempts: previousCommitFailedAttempts[target.candidate.identifier] ?? [],
                cleanupBeforeRun: Self.shouldCleanupBeforeRun(
                    targetID: target.candidate.identifier,
                    resumeBehavior: options.resumeBehavior,
                    previousTarget: previousTargetRecords[target.candidate.identifier]
                )
            )
            progressReporter?(.targetFinished(
                index: targetIndex,
                total: targetsToRun.count,
                displayName: target.candidate.displayName,
                status: targetResult.runTarget.status
            ))

            runRecord = Self.runRecordByAppending(
                targetResult.runTarget,
                to: runRecord,
                status: .running,
                endedAt: nil
            )
            targetRecords = Self.upserting(targetResult.manifestTarget, in: targetRecords)
            try repository.writeRun(runRecord)
            try repository.writeManifest(
                Self.manifest(
                    plan: plan,
                    runPlan: runPlan,
                    runID: runID,
                    targetRecords: targetRecords,
                    updatedAt: dateProvider()
                )
            )

            if targetResult.runTarget.status == .completed {
                generatedTargetIDs.append(target.candidate.identifier)
            }
        }

        let skippedTargetRecords = Self.skippedRunTargets(
            selectedTargets: selectedTargets,
            targetIDsToRun: targetIDsToRun
        )
        for skipped in skippedTargetRecords {
            runRecord = Self.runRecordByAppending(
                skipped,
                to: runRecord,
                status: .running,
                endedAt: nil
            )
        }

        let finalStatus = Self.finalRunStatus(for: runRecord.targetResults)
        let endedAt = dateProvider()
        runRecord = PrivateHeaderGeneration.RunRecord(
            runID: runRecord.runID,
            schemaVersion: runRecord.schemaVersion,
            toolVersion: runRecord.toolVersion,
            plan: runRecord.plan,
            startedAt: runRecord.startedAt,
            endedAt: endedAt,
            status: finalStatus,
            targetResults: runRecord.targetResults,
            attemptedArtifacts: runRecord.targetResults.flatMap(\.attemptedArtifacts),
            logs: runRecord.logs
        )
        try repository.writeRun(runRecord)
        try repository.writeManifest(
            Self.manifest(
                plan: plan,
                runPlan: runPlan,
                runID: runID,
                targetRecords: targetRecords,
                updatedAt: endedAt
            )
        )
        progressReporter?(.runFinished(
            runID: runID,
            status: finalStatus
        ))
        try repository.pruneRunHistory(from: repository.listRunSummaries())

        let failedTargetIDs = runRecord.targetResults
            .filter { !$0.status.isSuccessfulOrSkipped }
            .map(\.targetID)
        if !failedTargetIDs.isEmpty {
            throw PrivateHeaderGeneration.GenerationError.runFailed(
                runID: runID,
                failedTargetIDs: failedTargetIDs
            )
        }

        return PrivateHeaderGeneration.Result(
            plan: plan,
            generatedTargets: generatedTargetIDs.map(PrivateHeaderGeneration.Target.generated(identifier:)),
            runID: runID,
            manifestURL: repository.manifestURL,
            runRecordURL: try repository.runRecordURL(for: runID)
        )
    }

    func executeTarget(
        _ target: PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget,
        runID: String,
        runDirectories: PrivateHeaderGeneration.RunDirectories,
        plan: PrivateHeaderGeneration.Plan,
        helperURLs: PrivateHeaderGeneration.RawDumping.HelperURLs,
        executionMode: PrivateHeaderGeneration.RawDumping.ExecutionMode,
        rawDumpingOptions: PrivateHeaderGeneration.RawDumping.Options,
        artifactStore: PrivateHeaderGeneration.ArtifactStore,
        previousTarget: PrivateHeaderGeneration.TargetRecord?,
        previousCommitFailedAttempts: [PrivateHeaderGeneration.ArtifactPath],
        cleanupBeforeRun: Bool
    ) async throws -> TargetExecutionResult {
        let fileManager = FileManager.default
        let targetID = target.candidate.identifier
        let targetStagingDirectory = runDirectories.stagingDirectory
            .appendingPathComponent(Self.safeTargetDirectoryName(targetID), isDirectory: true)

        if fileManager.fileExists(atPath: targetStagingDirectory.path) {
            try fileManager.removeItem(at: targetStagingDirectory)
        }
        try fileManager.createDirectory(
            at: targetStagingDirectory,
            withIntermediateDirectories: true
        )

        var preservedArtifacts = previousTarget?.artifacts ?? []
        if cleanupBeforeRun {
            do {
                try artifactStore.cleanupManagedArtifacts(
                    PrivateHeaderGeneration.ArtifactStore.cleanupCandidates(
                        manifestArtifacts: preservedArtifacts,
                        attemptedArtifacts: previousCommitFailedAttempts
                    )
                )
                preservedArtifacts = []
            } catch {
                return failedTargetResult(
                    target: target,
                    runID: runID,
                    status: .commitFailed,
                    phases: [
                        PrivateHeaderGeneration.PhaseRecord(
                            name: "cleanup",
                            status: .failed,
                            failureSummary: "cleanup failed: \(error)"
                        ),
                    ],
                    artifacts: preservedArtifacts,
                    attemptedArtifacts: [],
                    failureSummary: "cleanup failed: \(error)"
                )
            }
        }

        let inputPath = Self.inputPath(for: target, executionMode: executionMode)
        let artifactRoot = try Self.artifactRoot(
            for: target,
            layout: plan.options.layout
        )
        let invocation = PrivateHeaderGeneration.RawDumping.makeInvocation(
            PrivateHeaderGeneration.RawDumping.Request(
                helperURLs: helperURLs,
                executionMode: executionMode,
                inputPath: inputPath,
                stagingOutputDirectory: targetStagingDirectory,
                options: rawDumpingOptions
            )
        )

        let rawResult: PrivateHeaderGeneration.RawDumping.Result
        do {
            rawResult = try await rawDumpRunner(invocation)
        } catch {
            let failureSummary = String(describing: error)
            return failedTargetResult(
                target: target,
                runID: runID,
                status: .failed,
                phases: [
                    PrivateHeaderGeneration.PhaseRecord(
                        name: invocation.phaseLabel,
                        status: .failed,
                        failureSummary: failureSummary
                    ),
                ],
                artifacts: preservedArtifacts,
                attemptedArtifacts: [],
                failureSummary: failureSummary
            )
        }

        let staged = try Self.collectStagedArtifacts(
            for: target,
            in: targetStagingDirectory,
            runtimeRoot: plan.options.systemRoot?.path ?? "",
            artifactRoot: artifactRoot
        )
        let attemptedArtifacts = staged.artifacts

        guard !attemptedArtifacts.isEmpty, let stagedSourceDirectory = staged.sourceDirectory else {
            let failureSummary = rawResult.succeeded
                ? "raw dump produced no header artifacts"
                : rawResult.failureSummary ?? "raw dump exited with status \(rawResult.terminationStatus)"
            return failedTargetResult(
                target: target,
                runID: runID,
                status: .failed,
                phases: [
                    PrivateHeaderGeneration.PhaseRecord(
                        name: invocation.phaseLabel,
                        status: .failed,
                        failureSummary: failureSummary
                    ),
                ],
                artifacts: preservedArtifacts,
                attemptedArtifacts: [],
                failureSummary: failureSummary
            )
        }

        let rawDumpPhase: PrivateHeaderGeneration.PhaseRecord
        let targetStatus: PrivateHeaderGeneration.RunTargetStatus
        let targetFailureSummary: String?
        if rawResult.succeeded {
            rawDumpPhase = PrivateHeaderGeneration.PhaseRecord(
                name: invocation.phaseLabel,
                status: .completed
            )
            targetStatus = .completed
            targetFailureSummary = nil
        } else {
            let failureSummary = rawResult.failureSummary
                ?? "raw dump exited with status \(rawResult.terminationStatus)"
            rawDumpPhase = PrivateHeaderGeneration.PhaseRecord(
                name: invocation.phaseLabel,
                status: .failed,
                failureSummary: failureSummary
            )
            targetStatus = .partial
            targetFailureSummary = failureSummary
        }

        do {
            try artifactStore.cleanupManagedArtifacts(
                PrivateHeaderGeneration.ArtifactStore.cleanupCandidates(
                    manifestArtifacts: preservedArtifacts,
                    attemptedArtifacts: previousCommitFailedAttempts
                )
            )
        } catch {
            let failureSummary = "cleanup failed: \(error)"
            return failedTargetResult(
                target: target,
                runID: runID,
                status: .commitFailed,
                phases: [
                    rawDumpPhase,
                    PrivateHeaderGeneration.PhaseRecord(
                        name: "cleanup",
                        status: .failed,
                        failureSummary: failureSummary
                    ),
                ],
                artifacts: preservedArtifacts,
                attemptedArtifacts: attemptedArtifacts,
                failureSummary: failureSummary
            )
        }

        do {
            try Self.commit(
                stagedSourceDirectory: stagedSourceDirectory,
                artifactRoot: artifactRoot,
                artifactDirectory: plan.artifactDirectory
            )
        } catch {
            let failureSummary = "commit failed: \(error)"
            return failedTargetResult(
                target: target,
                runID: runID,
                status: .commitFailed,
                phases: [
                    rawDumpPhase,
                    PrivateHeaderGeneration.PhaseRecord(
                        name: "commit",
                        status: .failed,
                        failureSummary: failureSummary
                    ),
                ],
                artifacts: [],
                attemptedArtifacts: attemptedArtifacts,
                failureSummary: failureSummary
            )
        }

        let phases = [
            rawDumpPhase,
            PrivateHeaderGeneration.PhaseRecord(
                name: "commit",
                status: .completed
            ),
        ]
        let manifestTarget = PrivateHeaderGeneration.TargetRecord(
            id: targetID,
            displayName: target.candidate.displayName,
            kind: target.candidate.kind.rawValue,
            status: PrivateHeaderGeneration.TargetStatus(runStatus: targetStatus),
            phases: phases,
            artifacts: attemptedArtifacts,
            lastRunID: runID,
            updatedAt: dateProvider(),
            failureSummary: targetFailureSummary
        )
        let runTarget = PrivateHeaderGeneration.RunTargetRecord(
            targetID: targetID,
            status: targetStatus,
            phases: phases,
            artifacts: attemptedArtifacts,
            attemptedArtifacts: attemptedArtifacts,
            failureSummary: targetFailureSummary
        )
        return TargetExecutionResult(runTarget: runTarget, manifestTarget: manifestTarget)
    }

    func failedTargetResult(
        target: PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget,
        runID: String,
        status: PrivateHeaderGeneration.RunTargetStatus,
        phases: [PrivateHeaderGeneration.PhaseRecord],
        artifacts: [PrivateHeaderGeneration.ArtifactPath],
        attemptedArtifacts: [PrivateHeaderGeneration.ArtifactPath],
        failureSummary: String
    ) -> TargetExecutionResult {
        let manifestTarget = PrivateHeaderGeneration.TargetRecord(
            id: target.candidate.identifier,
            displayName: target.candidate.displayName,
            kind: target.candidate.kind.rawValue,
            status: PrivateHeaderGeneration.TargetStatus(runStatus: status),
            phases: phases,
            artifacts: artifacts,
            lastRunID: runID,
            updatedAt: dateProvider(),
            failureSummary: failureSummary
        )
        let runTarget = PrivateHeaderGeneration.RunTargetRecord(
            targetID: target.candidate.identifier,
            status: status,
            phases: phases,
            artifacts: [],
            attemptedArtifacts: attemptedArtifacts,
            failureSummary: failureSummary
        )
        return TargetExecutionResult(runTarget: runTarget, manifestTarget: manifestTarget)
    }
}

private extension PrivateHeaderGeneration.GenerationExecutor {
    static func selectedExecutionTargets(
        request: PrivateHeaderGeneration.TargetRequest,
        catalog: PrivateHeaderGeneration.TargetDiscovery.Catalog
    ) throws -> [PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget] {
        switch request {
        case .frameworks:
            return Self.deduplicated(
                catalog.targets.flatMap { target -> [PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget] in
                    guard target.candidate.kind == .framework || target.candidate.kind == .privateFramework else {
                        return []
                    }
                    return [target] + target.childTargets
                }
            )
        case .system:
            return Self.deduplicated(
                catalog.targets.flatMap { target -> [PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget] in
                    guard target.candidate.kind != .usrLibDylib else {
                        return []
                    }
                    return [target] + target.childTargets
                }
            )
        case .allAvailable:
            return Self.deduplicated(catalog.allTargetsIncludingNestedChildren)
        case .identifiers(let targetIDs):
            let requestedTargetIDs = Self.deduplicatedTargetIDs(targetIDs)
            let targets = catalog.allTargetsIncludingNestedChildren
            let selected = requestedTargetIDs.compactMap { targetID in
                targets.first { $0.candidate.identifier == targetID }
            }
            if selected.count != requestedTargetIDs.count {
                let selectedIDs = Set(selected.map(\.candidate.identifier))
                let missing = requestedTargetIDs.filter { !selectedIDs.contains($0) }.sorted()
                throw PrivateHeaderGeneration.GenerationError.unknownSelectedTargets(missing)
            }
            return Self.deduplicated(selected)
        case .query(let query):
            let targetQuery = try PrivateHeaderGeneration.TargetQuery(commaSeparated: query)
            switch catalog.resolver.resolve(targetQuery) {
            case .selected(.allAvailable):
                return Self.deduplicated(catalog.allTargetsIncludingNestedChildren)
            case .selected(.targets(let candidates)):
                let selected = candidates.flatMap { candidate in
                    Self.expandTarget(
                        identifier: candidate.identifier,
                        catalog: catalog
                    )
                }
                return Self.deduplicated(selected)
            case .needsDisambiguation, .failed, .unresolved:
                throw PrivateHeaderGeneration.GenerationError.unresolvedTargetQuery(query)
            }
        }
    }

    static func expandTarget(
        identifier: String,
        catalog: PrivateHeaderGeneration.TargetDiscovery.Catalog
    ) -> [PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget] {
        for target in catalog.targets where target.candidate.identifier == identifier {
            return [target] + target.childTargets
        }
        return catalog.allTargetsIncludingNestedChildren.filter {
            $0.candidate.identifier == identifier
        }
    }

    static func deduplicated(
        _ targets: [PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget]
    ) -> [PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget] {
        var seen: Set<String> = []
        var deduplicated: [PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget] = []
        for target in targets where seen.insert(target.candidate.identifier).inserted {
            deduplicated.append(target)
        }
        return deduplicated
    }

    static func deduplicatedTargetIDs(_ targetIDs: [String]) -> [String] {
        var seen: Set<String> = []
        var deduplicated: [String] = []
        for targetID in targetIDs where seen.insert(targetID).inserted {
            deduplicated.append(targetID)
        }
        return deduplicated
    }
}

private extension PrivateHeaderGeneration.GenerationExecutor {
    static func resumeSummary(
        for behavior: PrivateHeaderGeneration.ResumeBehavior,
        runPlan: PrivateHeaderGeneration.RunPlanRecord,
        manifest: PrivateHeaderGeneration.Manifest?,
        latestRun: PrivateHeaderGeneration.RunRecord?,
        artifactStore: PrivateHeaderGeneration.ArtifactStore
    ) throws -> PrivateHeaderGeneration.ResumeSummary? {
        guard let manifest else {
            return nil
        }

        if case .fresh = behavior {
            return nil
        }

        let artifactExists: PrivateHeaderGeneration.ArtifactExistence = { artifact in
            (try? artifactStore.contains(artifact)) == true
        }

        switch PrivateHeaderGeneration.nonInteractiveResumeDecision(
            plan: runPlan,
            manifest: manifest,
            latestRun: latestRun,
            resumeRequested: behavior.resumeRequested,
            artifactExists: artifactExists
        ) {
        case .proceed:
            return PrivateHeaderGeneration.makeResumeSummary(
                plan: runPlan,
                manifest: manifest,
                latestRun: latestRun,
                artifactExists: artifactExists
            )
        case .resume(let summary):
            return summary
        case .resumeRequired(let summary):
            throw PrivateHeaderGeneration.GenerationError.resumeRequired(summary)
        case .incompatible(let reasons):
            throw PrivateHeaderGeneration.GenerationError.incompatibleResume(reasons)
        }
    }

    static func targetIDsToRun(
        resumeBehavior: PrivateHeaderGeneration.ResumeBehavior,
        selectedTargets: [PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget],
        resumeSummary: PrivateHeaderGeneration.ResumeSummary?
    ) -> Set<String> {
        if case .fresh = resumeBehavior {
            return Set(selectedTargets.map(\.candidate.identifier))
        }
        guard let resumeSummary else {
            return Set(selectedTargets.map(\.candidate.identifier))
        }
        return Set(resumeSummary.targetIDsToRun)
    }

    static func shouldCleanupBeforeRun(
        targetID: String,
        resumeBehavior: PrivateHeaderGeneration.ResumeBehavior,
        previousTarget: PrivateHeaderGeneration.TargetRecord?
    ) -> Bool {
        if case .fresh = resumeBehavior {
            return true
        }
        return previousTarget?.id == targetID && previousTarget?.status == .commitFailed
    }

    static func skippedRunTargets(
        selectedTargets: [PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget],
        targetIDsToRun: Set<String>
    ) -> [PrivateHeaderGeneration.RunTargetRecord] {
        selectedTargets
            .filter { !targetIDsToRun.contains($0.candidate.identifier) }
            .map { target in
                PrivateHeaderGeneration.RunTargetRecord(
                    targetID: target.candidate.identifier,
                    status: .skipped,
                    phases: [
                        PrivateHeaderGeneration.PhaseRecord(
                            name: "raw-header-dump",
                            status: .skipped
                        ),
                    ],
                    artifacts: [],
                    attemptedArtifacts: [],
                    failureSummary: nil
                )
            }
    }
}

private extension PrivateHeaderGeneration.GenerationExecutor {
    struct StagedArtifacts {
        let sourceDirectory: URL?
        let artifacts: [PrivateHeaderGeneration.ArtifactPath]
    }

    static func collectStagedArtifacts(
        for target: PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget,
        in targetStagingDirectory: URL,
        runtimeRoot: String,
        artifactRoot: PrivateHeaderGeneration.ArtifactPath
    ) throws -> StagedArtifacts {
        var firstExistingDirectory: URL?
        var firstArtifacts: [PrivateHeaderGeneration.ArtifactPath] = []

        let candidates = stagedSourceDirectoryCandidates(
            for: target,
            in: targetStagingDirectory,
            runtimeRoot: runtimeRoot
        )

        for candidate in candidates where isDirectory(candidate) {
            let artifacts = try artifactPaths(
                under: candidate,
                artifactRoot: artifactRoot
            )
            if firstExistingDirectory == nil {
                firstExistingDirectory = candidate
                firstArtifacts = artifacts
            }
            if !artifacts.isEmpty {
                return StagedArtifacts(
                    sourceDirectory: candidate,
                    artifacts: artifacts
                )
            }
        }

        return StagedArtifacts(
            sourceDirectory: firstExistingDirectory,
            artifacts: firstArtifacts
        )
    }

    static func stagedSourceDirectoryCandidates(
        for target: PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget,
        in targetStagingDirectory: URL,
        runtimeRoot: String
    ) -> [URL] {
        let runtimeInputPath = target.runtimeInputPath
        let trimmedRuntimePath = runtimeInputPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if runtimeInputPath.hasPrefix("/usr/lib/") {
            let name = URL(fileURLWithPath: runtimeInputPath).lastPathComponent
            return stageUsrLibRoots(
                stageDirectory: targetStagingDirectory,
                runtimeRoot: runtimeRoot
            )
            .map { $0.appendingPathComponent(name, isDirectory: true) }
        }

        let systemLibraryRelativePath = String(runtimeInputPath.dropFirst("/System/Library/".count))
        var candidates = stageSystemLibraryRoots(
            stageDirectory: targetStagingDirectory,
            runtimeRoot: runtimeRoot
        )
        .map { appendRelativePath(systemLibraryRelativePath, to: $0) }
        candidates.append(appendRelativePath(trimmedRuntimePath, to: targetStagingDirectory))
        return candidates
    }

    static func artifactPaths(
        under sourceDirectory: URL,
        artifactRoot: PrivateHeaderGeneration.ArtifactPath
    ) throws -> [PrivateHeaderGeneration.ArtifactPath] {
        guard let enumerator = FileManager.default.enumerator(
            at: sourceDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let sourcePath = sourceDirectory.standardizedFileURL.path
        var artifacts: [PrivateHeaderGeneration.ArtifactPath] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true {
                continue
            }
            guard url.pathExtension == "h" || url.pathExtension == "swiftinterface" else {
                continue
            }

            let path = url.standardizedFileURL.path
            let relativePath = path.hasPrefix(sourcePath + "/")
                ? String(path.dropFirst(sourcePath.count + 1))
                : url.lastPathComponent
            artifacts.append(
                try PrivateHeaderGeneration.ArtifactPath(
                    artifactRoot.rawValue + "/" + relativePath
                )
            )
        }

        return artifacts.sorted { $0.rawValue < $1.rawValue }
    }

    static func commit(
        stagedSourceDirectory: URL,
        artifactRoot: PrivateHeaderGeneration.ArtifactPath,
        artifactDirectory: URL
    ) throws {
        let destination = appendRelativePath(artifactRoot.rawValue, to: artifactDirectory)
        try mergeDirectoryContents(
            from: stagedSourceDirectory,
            to: destination
        )
    }

    static func artifactRoot(
        for target: PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget,
        layout: PrivateHeaderGeneration.Layout
    ) throws -> PrivateHeaderGeneration.ArtifactPath {
        switch layout {
        case .headers:
            return target.artifactRoot
        case .bundle:
            return try bundleArtifactRoot(for: target.source)
        }
    }

    static func bundleArtifactRoot(
        for source: PrivateHeaderGeneration.TargetDiscovery.SourceMetadata
    ) throws -> PrivateHeaderGeneration.ArtifactPath {
        switch source {
        case .framework(let framework):
            return try PrivateHeaderGeneration.ArtifactPath(
                framework.systemLibraryRelativePath
            )
        case .systemLibraryBundle(let bundle):
            return try PrivateHeaderGeneration.ArtifactPath(
                artifactRootForBundleLayout(systemLibraryRelativePath: bundle.relativePath)
            )
        case .usrLibDylib(let dylib):
            return try PrivateHeaderGeneration.ArtifactPath("usr/lib/\(dylib.name)")
        }
    }

    static func artifactRootForBundleLayout(systemLibraryRelativePath: String) -> String {
        let firstComponent = systemLibraryRelativePath.split(separator: "/", maxSplits: 1).first
        if firstComponent == "Frameworks" || firstComponent == "PrivateFrameworks" {
            return systemLibraryRelativePath
        }
        return "SystemLibrary/\(systemLibraryRelativePath)"
    }
}

private extension PrivateHeaderGeneration.GenerationExecutor {
    static func manifest(
        plan: PrivateHeaderGeneration.Plan,
        runPlan: PrivateHeaderGeneration.RunPlanRecord,
        runID: String,
        targetRecords: [PrivateHeaderGeneration.TargetRecord],
        updatedAt: Date
    ) -> PrivateHeaderGeneration.Manifest {
        PrivateHeaderGeneration.Manifest(
            schemaVersion: 1,
            toolVersion: plan.options.toolVersion,
            source: runPlan.source,
            output: runPlan.output,
            layout: plan.options.layout,
            latestRunID: runID,
            targets: targetRecords,
            updatedAt: updatedAt
        )
    }

    static func runPlanRecord(
        plan: PrivateHeaderGeneration.Plan,
        selectedTargets: [PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget],
        executionMode: PrivateHeaderGeneration.RawDumping.ExecutionMode,
        helperEnvironment: [String: String]
    ) -> PrivateHeaderGeneration.RunPlanRecord {
        PrivateHeaderGeneration.RunPlanRecord(
            source: PrivateHeaderGeneration.SourceRecord(source: plan.source),
            output: PrivateHeaderGeneration.OutputRecord(
                plan: plan,
                baseDirectory: plan.options.outputBaseDirectory ?? plan.output.artifactBaseDirectory
            ),
            layout: plan.options.layout,
            targetIDs: selectedTargets.map(\.candidate.identifier),
            execution: Self.executionRecord(
                for: executionMode,
                helperEnvironment: helperEnvironment
            )
        )
    }

    static func executionRecord(
        for executionMode: PrivateHeaderGeneration.RawDumping.ExecutionMode,
        helperEnvironment: [String: String]
    ) -> PrivateHeaderGeneration.ExecutionRecord {
        switch executionMode {
        case .host:
            return PrivateHeaderGeneration.ExecutionRecord(
                mode: "host",
                runtimeIdentifier: nil,
                deviceName: nil,
                deviceUDID: nil,
                clonePolicy: nil,
                helperEnvironment: helperEnvironment
            )
        case .simulator(let deviceUDID, _):
            return PrivateHeaderGeneration.ExecutionRecord(
                mode: "simulator",
                runtimeIdentifier: nil,
                deviceName: nil,
                deviceUDID: deviceUDID,
                clonePolicy: nil,
                helperEnvironment: helperEnvironment
            )
        }
    }

    static func runRecordByAppending(
        _ target: PrivateHeaderGeneration.RunTargetRecord,
        to run: PrivateHeaderGeneration.RunRecord,
        status: PrivateHeaderGeneration.RunTargetStatus,
        endedAt: Date?
    ) -> PrivateHeaderGeneration.RunRecord {
        PrivateHeaderGeneration.RunRecord(
            runID: run.runID,
            schemaVersion: run.schemaVersion,
            toolVersion: run.toolVersion,
            plan: run.plan,
            startedAt: run.startedAt,
            endedAt: endedAt,
            status: status,
            targetResults: run.targetResults + [target],
            attemptedArtifacts: run.attemptedArtifacts + target.attemptedArtifacts,
            logs: run.logs
        )
    }

    static func finalRunStatus(
        for targetResults: [PrivateHeaderGeneration.RunTargetRecord]
    ) -> PrivateHeaderGeneration.RunTargetStatus {
        let executableResults = targetResults.filter { $0.status != .skipped }
        guard !executableResults.isEmpty else {
            return .completed
        }
        if executableResults.allSatisfy({ $0.status == .completed }) {
            return .completed
        }
        if executableResults.contains(where: { $0.status == .commitFailed }) {
            return .commitFailed
        }
        if executableResults.contains(where: { $0.status == .interrupted }) {
            return .interrupted
        }
        if executableResults.contains(where: { $0.status == .partial || $0.status == .completed }) {
            return .partial
        }
        return .failed
    }

    static func upserting(
        _ record: PrivateHeaderGeneration.TargetRecord,
        in records: [PrivateHeaderGeneration.TargetRecord]
    ) -> [PrivateHeaderGeneration.TargetRecord] {
        var records = records
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        return records
    }

    static func targetsByID(
        _ targets: [PrivateHeaderGeneration.TargetRecord]
    ) -> [String: PrivateHeaderGeneration.TargetRecord] {
        var targetsByID: [String: PrivateHeaderGeneration.TargetRecord] = [:]
        for target in targets {
            targetsByID[target.id] = target
        }
        return targetsByID
    }

    static func commitFailedAttemptedArtifactsByTargetID(
        _ run: PrivateHeaderGeneration.RunRecord?
    ) -> [String: [PrivateHeaderGeneration.ArtifactPath]] {
        guard let run else {
            return [:]
        }
        var result: [String: [PrivateHeaderGeneration.ArtifactPath]] = [:]
        for target in run.targetResults where target.status == .commitFailed {
            result[target.targetID] = target.attemptedArtifacts
        }
        return result
    }
}

public extension PrivateHeaderGeneration.GenerationExecutor {
    static func liveRawDumpRunner(
        invocation: PrivateHeaderGeneration.RawDumping.Invocation
    ) async throws -> PrivateHeaderGeneration.RawDumping.Result {
        let process = Process()
        let outputPipe = Pipe()
        let outputCapture = RawDumpOutputCapture()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = invocation.command
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        if !invocation.environment.isEmpty {
            var environment = ProcessInfo.processInfo.environment
            invocation.environment.forEach { key, value in
                environment[key] = value
            }
            process.environment = environment
        }

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                outputCapture.append(data)
            }
        }
        defer {
            outputPipe.fileHandleForReading.readabilityHandler = nil
        }

        try process.run()
        process.waitUntilExit()
        outputPipe.fileHandleForReading.readabilityHandler = nil
        outputCapture.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
        let wasKilled = process.terminationReason == .uncaughtSignal
        let terminationStatus = process.terminationStatus
        let failureSummary = Self.rawDumpFailureSummary(
            terminationStatus: terminationStatus,
            wasKilled: wasKilled,
            outputLines: outputCapture.lines()
        )
        return PrivateHeaderGeneration.RawDumping.Result(
            terminationStatus: terminationStatus,
            wasKilled: wasKilled,
            failureSummary: failureSummary
        )
    }

    static func rawDumpFailureSummary(
        terminationStatus: Int32,
        wasKilled: Bool,
        outputLines: [String]
    ) -> String? {
        guard terminationStatus != 0 || wasKilled else {
            return nil
        }

        let statusLine: String
        if wasKilled {
            if let signalName = rawDumpSignalName(terminationStatus) {
                statusLine = "raw dump terminated by signal \(terminationStatus): \(signalName)"
            } else {
                statusLine = "raw dump terminated by signal \(terminationStatus)"
            }
        } else {
            statusLine = "raw dump exited with status \(terminationStatus)"
        }

        let capturedLines = outputLines.suffix(8)
        guard !capturedLines.isEmpty else {
            return statusLine
        }
        return ([statusLine] + capturedLines).joined(separator: "\n")
    }

    private static func rawDumpSignalName(_ signal: Int32) -> String? {
        switch signal {
        case 5:
            return "Trace/BPT trap"
        case 9:
            return "Killed"
        case 10:
            return "Bus error"
        case 11:
            return "Segmentation fault"
        case 15:
            return "Terminated"
        default:
            return nil
        }
    }
}

private final class RawDumpOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumByteCount = 16 * 1024
    private var buffer = Data()

    func append(_ data: Data) {
        guard !data.isEmpty else {
            return
        }
        lock.lock()
        defer {
            lock.unlock()
        }

        buffer.append(data)
        if buffer.count > maximumByteCount {
            buffer.removeFirst(buffer.count - maximumByteCount)
        }
    }

    func lines() -> [String] {
        lock.lock()
        defer {
            lock.unlock()
        }

        return String(decoding: buffer, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private extension PrivateHeaderGeneration.ResumeBehavior {
    var resumeRequested: Bool {
        switch self {
        case .resume:
            return true
        case .fresh:
            return false
        case .requireExplicitResume(let resumeRequested):
            return resumeRequested
        }
    }
}

private extension PrivateHeaderGeneration.RawDumping.Options {
    func recordedHelperEnvironment(
        for executionMode: PrivateHeaderGeneration.RawDumping.ExecutionMode
    ) -> [String: String] {
        var environment = helperEnvironment
        if case .simulator(_, let runtimeRoot) = executionMode {
            environment["PH_RUNTIME_ROOT"] = runtimeRoot
            environment["SIMCTL_CHILD_PH_RUNTIME_ROOT"] = runtimeRoot
            environment["SIMCTL_CHILD_DYLD_ROOT_PATH"] = runtimeRoot
        }
        return environment
    }
}

private extension PrivateHeaderGeneration.TargetStatus {
    init(runStatus: PrivateHeaderGeneration.RunTargetStatus) {
        switch runStatus {
        case .completed, .skipped, .running, .pending:
            self = .completed
        case .partial:
            self = .partial
        case .failed:
            self = .failed
        case .interrupted:
            self = .interrupted
        case .commitFailed:
            self = .commitFailed
        }
    }
}

private extension PrivateHeaderGeneration.RunTargetStatus {
    var isSuccessfulOrSkipped: Bool {
        self == .completed || self == .skipped
    }
}

private extension PrivateHeaderGeneration.GenerationExecutor {
    static func inputPath(
        for target: PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget,
        executionMode: PrivateHeaderGeneration.RawDumping.ExecutionMode
    ) -> String {
        switch executionMode {
        case .host:
            return target.inputPath
        case .simulator:
            return target.runtimeInputPath
        }
    }

    static func safeTargetDirectoryName(_ targetID: String) -> String {
        var result = ""
        for byte in targetID.utf8 {
            let isAlphaNumeric = (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
            let isSafePunctuation = byte == 45 || byte == 46 || byte == 95
            if isAlphaNumeric || isSafePunctuation {
                result.append(Character(UnicodeScalar(byte)))
            } else {
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }

    static func stageSystemLibraryRoots(
        stageDirectory: URL,
        runtimeRoot: String
    ) -> [URL] {
        var roots: [URL] = [
            stageDirectory.appendingPathComponent("System/Library", isDirectory: true),
            stageDirectory.appendingPathComponent(
                "System/Cryptexes/OS/System/Library",
                isDirectory: true
            ),
            stageDirectory.appendingPathComponent(
                "System/Volumes/Preboot/Cryptexes/OS/System/Library",
                isDirectory: true
            ),
        ]

        if runtimeRoot.hasPrefix("/") {
            let base = appendRelativePath(
                String(runtimeRoot.dropFirst()),
                to: stageDirectory
            )
            roots.append(base.appendingPathComponent("System/Library", isDirectory: true))
            roots.append(
                base.appendingPathComponent(
                    "System/Cryptexes/OS/System/Library",
                    isDirectory: true
                )
            )
            roots.append(
                base.appendingPathComponent(
                    "System/Volumes/Preboot/Cryptexes/OS/System/Library",
                    isDirectory: true
                )
            )
        }

        return roots.uniquedByPath()
    }

    static func stageUsrLibRoots(
        stageDirectory: URL,
        runtimeRoot: String
    ) -> [URL] {
        var roots: [URL] = [
            stageDirectory
                .appendingPathComponent("usr", isDirectory: true)
                .appendingPathComponent("lib", isDirectory: true),
        ]

        if runtimeRoot.hasPrefix("/") {
            let base = appendRelativePath(
                String(runtimeRoot.dropFirst()),
                to: stageDirectory
            )
            roots.append(
                base
                    .appendingPathComponent("usr", isDirectory: true)
                    .appendingPathComponent("lib", isDirectory: true)
            )
        }

        return roots.uniquedByPath()
    }

    static func appendRelativePath(_ relativePath: String, to base: URL) -> URL {
        var url = base
        for component in relativePath.split(separator: "/", omittingEmptySubsequences: false) {
            url.appendPathComponent(String(component), isDirectory: true)
        }
        return url
    }

    static func mergeDirectoryContents(
        from source: URL,
        to destination: URL
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let entries = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )

        for entry in entries {
            let destinationEntry = destination.appendingPathComponent(
                entry.lastPathComponent,
                isDirectory: false
            )
            if isDirectory(entry) {
                try mergeDirectoryContents(from: entry, to: destinationEntry)
            } else {
                if fileManager.fileExists(atPath: destinationEntry.path) {
                    try fileManager.removeItem(at: destinationEntry)
                }
                try fileManager.createDirectory(
                    at: destinationEntry.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: entry, to: destinationEntry)
            }
        }
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

private extension Array where Element == URL {
    func uniquedByPath() -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []
        for url in self where seen.insert(url.path).inserted {
            result.append(url)
        }
        return result
    }
}
