import Foundation

public extension PrivateHeaderGeneration {
    typealias ArtifactExistence = @Sendable (ArtifactPath) -> Bool

    enum ResumeCompatibilityRecord: String, Hashable, Sendable {
        case manifest
        case run
    }

    enum ResumeCompatibilityReason: Equatable, Sendable {
        case unsupportedManifestSchema(actual: Int, supported: [Int])
        case unsupportedRunSchema(actual: Int, supported: [Int])
        case sourceBuildMismatch(
            expected: SourceRecord,
            actual: SourceRecord,
            record: ResumeCompatibilityRecord
        )
        case outputMismatch(
            expected: OutputRecord,
            actual: OutputRecord,
            record: ResumeCompatibilityRecord
        )
        case layoutMismatch(
            expected: Layout,
            actual: Layout,
            record: ResumeCompatibilityRecord
        )
        case selectedTargetSetMismatch(
            expected: [String],
            actual: [String],
            record: ResumeCompatibilityRecord
        )
        case executionMismatch(
            expected: ExecutionRecord,
            actual: ExecutionRecord,
            record: ResumeCompatibilityRecord
        )
        case missingLatestRun(runID: String)
    }

    enum ResumeCompatibility: Equatable, Sendable {
        case compatible
        case incompatible([ResumeCompatibilityReason])

        public var isCompatible: Bool {
            self == .compatible
        }
    }

    enum ResumeTargetStatus: String, Hashable, Sendable {
        case completed
        case partial
        case failed
        case interrupted
        case commitFailed
        case stale
        case pending
    }

    struct ResumeTargetDecision: Equatable, Sendable {
        public let targetID: String
        public let status: ResumeTargetStatus

        public init(targetID: String, status: ResumeTargetStatus) {
            self.targetID = targetID
            self.status = status
        }

        public var shouldRun: Bool {
            status != .completed
        }
    }

    struct ResumeTargetCounts: Equatable, Sendable {
        public let total: Int
        public let completed: Int
        public let partial: Int
        public let failed: Int
        public let interrupted: Int
        public let commitFailed: Int
        public let stale: Int
        public let pending: Int

        public init(
            total: Int,
            completed: Int,
            partial: Int,
            failed: Int,
            interrupted: Int,
            commitFailed: Int,
            stale: Int,
            pending: Int
        ) {
            self.total = total
            self.completed = completed
            self.partial = partial
            self.failed = failed
            self.interrupted = interrupted
            self.commitFailed = commitFailed
            self.stale = stale
            self.pending = pending
        }

        public var unfinished: Int {
            partial + failed + interrupted + commitFailed + stale + pending
        }

        fileprivate init(targets: [ResumeTargetDecision]) {
            var completed = 0
            var partial = 0
            var failed = 0
            var interrupted = 0
            var commitFailed = 0
            var stale = 0
            var pending = 0

            for target in targets {
                switch target.status {
                case .completed:
                    completed += 1
                case .partial:
                    partial += 1
                case .failed:
                    failed += 1
                case .interrupted:
                    interrupted += 1
                case .commitFailed:
                    commitFailed += 1
                case .stale:
                    stale += 1
                case .pending:
                    pending += 1
                }
            }

            self.init(
                total: targets.count,
                completed: completed,
                partial: partial,
                failed: failed,
                interrupted: interrupted,
                commitFailed: commitFailed,
                stale: stale,
                pending: pending
            )
        }
    }

    struct ResumeSummary: Equatable, Sendable {
        public let source: SourceRecord
        public let output: OutputRecord
        public let layout: Layout
        public let latestRunID: String?
        public let startedAt: Date?
        public let updatedAt: Date
        public let counts: ResumeTargetCounts
        public let targets: [ResumeTargetDecision]

        public init(
            source: SourceRecord,
            output: OutputRecord,
            layout: Layout,
            latestRunID: String?,
            startedAt: Date?,
            updatedAt: Date,
            counts: ResumeTargetCounts,
            targets: [ResumeTargetDecision]
        ) {
            self.source = source
            self.output = output
            self.layout = layout
            self.latestRunID = latestRunID
            self.startedAt = startedAt
            self.updatedAt = updatedAt
            self.counts = counts
            self.targets = targets
        }

        public var targetIDsToRun: [String] {
            targets.filter(\.shouldRun).map(\.targetID)
        }

        public var isUnfinished: Bool {
            counts.unfinished > 0
        }
    }

    enum NonInteractiveResumeDecision: Equatable, Sendable {
        case proceed
        case resume(ResumeSummary)
        case resumeRequired(ResumeSummary)
        case incompatible([ResumeCompatibilityReason])
    }
}

public extension PrivateHeaderGeneration {
    static func evaluateResumeCompatibility(
        plan: RunPlanRecord,
        manifest: Manifest,
        latestRun: RunRecord? = nil,
        supportedSchemaVersions: Set<Int> = [1]
    ) -> ResumeCompatibility {
        let supported = supportedSchemaVersions.sorted()
        var reasons: [ResumeCompatibilityReason] = []

        if !supportedSchemaVersions.contains(manifest.schemaVersion) {
            reasons.append(
                .unsupportedManifestSchema(
                    actual: manifest.schemaVersion,
                    supported: supported
                )
            )
        }

        let manifestPlan = RunPlanRecord(
            source: manifest.source,
            output: manifest.output,
            layout: manifest.layout,
            targetIDs: manifest.targets.map(\.id)
        )
        appendCompatibilityMismatches(
            to: &reasons,
            expected: plan,
            actual: manifestPlan,
            record: .manifest,
            compareTargetSet: false,
            compareExecution: false
        )

        if let latestRun {
            if !supportedSchemaVersions.contains(latestRun.schemaVersion) {
                reasons.append(
                    .unsupportedRunSchema(
                        actual: latestRun.schemaVersion,
                        supported: supported
                    )
                )
            }

            appendCompatibilityMismatches(
                to: &reasons,
                expected: plan,
                actual: latestRun.plan,
                record: .run,
                compareTargetSet: true,
                compareExecution: true
            )
        } else if reasons.isEmpty, let latestRunID = manifest.latestRunID {
            reasons.append(.missingLatestRun(runID: latestRunID))
        }

        if reasons.isEmpty {
            return .compatible
        }
        return .incompatible(reasons)
    }

    static func makeResumeSummary(
        plan: RunPlanRecord,
        manifest: Manifest,
        latestRun: RunRecord? = nil,
        artifactExists: ArtifactExistence
    ) -> ResumeSummary {
        let targets = resumeTargetDecisions(
            plan: plan,
            manifest: manifest,
            artifactExists: artifactExists
        )

        return ResumeSummary(
            source: manifest.source,
            output: manifest.output,
            layout: manifest.layout,
            latestRunID: manifest.latestRunID,
            startedAt: latestRun?.startedAt,
            updatedAt: manifest.updatedAt,
            counts: ResumeTargetCounts(targets: targets),
            targets: targets
        )
    }

    static func resumeTargetDecisions(
        plan: RunPlanRecord,
        manifest: Manifest,
        artifactExists: ArtifactExistence
    ) -> [ResumeTargetDecision] {
        let targetsByID = manifestTargetsByID(manifest.targets)
        return deduplicatedTargetIDs(plan.targetIDs).map { targetID in
            let status: ResumeTargetStatus
            if let target = targetsByID[targetID] {
                status = resumeStatus(for: target, artifactExists: artifactExists)
            } else {
                status = .pending
            }
            return ResumeTargetDecision(targetID: targetID, status: status)
        }
    }

    static func targetIDsToRunOnResume(
        plan: RunPlanRecord,
        manifest: Manifest,
        artifactExists: ArtifactExistence
    ) -> [String] {
        resumeTargetDecisions(
            plan: plan,
            manifest: manifest,
            artifactExists: artifactExists
        )
        .filter(\.shouldRun)
        .map(\.targetID)
    }

    static func nonInteractiveResumeDecision(
        plan: RunPlanRecord,
        manifest: Manifest,
        latestRun: RunRecord? = nil,
        resumeRequested: Bool,
        artifactExists: ArtifactExistence,
        supportedSchemaVersions: Set<Int> = [1]
    ) -> NonInteractiveResumeDecision {
        let compatibility = evaluateResumeCompatibility(
            plan: plan,
            manifest: manifest,
            latestRun: latestRun,
            supportedSchemaVersions: supportedSchemaVersions
        )
        if case .incompatible(let reasons) = compatibility {
            return .incompatible(reasons)
        }

        let summary = makeResumeSummary(
            plan: plan,
            manifest: manifest,
            latestRun: latestRun,
            artifactExists: artifactExists
        )
        if resumeRequested {
            return .resume(summary)
        }
        if summary.isUnfinished {
            return .resumeRequired(summary)
        }
        return .proceed
    }
}

private extension PrivateHeaderGeneration {
    static func appendCompatibilityMismatches(
        to reasons: inout [ResumeCompatibilityReason],
        expected: RunPlanRecord,
        actual: RunPlanRecord,
        record: ResumeCompatibilityRecord,
        compareTargetSet: Bool,
        compareExecution: Bool
    ) {
        if expected.source != actual.source {
            reasons.append(
                .sourceBuildMismatch(
                    expected: expected.source,
                    actual: actual.source,
                    record: record
                )
            )
        }

        if expected.output != actual.output {
            reasons.append(
                .outputMismatch(
                    expected: expected.output,
                    actual: actual.output,
                    record: record
                )
            )
        }

        if expected.layout != actual.layout {
            reasons.append(
                .layoutMismatch(
                    expected: expected.layout,
                    actual: actual.layout,
                    record: record
                )
            )
        }

        if compareTargetSet {
            let expectedIDs = normalizedTargetIDs(expected.targetIDs)
            let actualIDs = normalizedTargetIDs(actual.targetIDs)
            if !isPreviousTargetSetCompatibleWithCurrentPlan(
                previousTargetIDs: actualIDs,
                currentTargetIDs: expectedIDs
            ) {
                reasons.append(
                    .selectedTargetSetMismatch(
                        expected: expectedIDs,
                        actual: actualIDs,
                        record: record
                    )
                )
            }
        }

        if compareExecution, expected.execution != actual.execution {
            reasons.append(
                .executionMismatch(
                    expected: expected.execution,
                    actual: actual.execution,
                    record: record
                )
            )
        }
    }

    static func isPreviousTargetSetCompatibleWithCurrentPlan(
        previousTargetIDs: [String],
        currentTargetIDs: [String]
    ) -> Bool {
        Set(previousTargetIDs).isSubset(of: Set(currentTargetIDs))
    }

    static func resumeStatus(
        for target: TargetRecord,
        artifactExists: ArtifactExistence
    ) -> ResumeTargetStatus {
        switch target.status {
        case .completed:
            return hasCompleteManagedArtifacts(target, artifactExists: artifactExists) ? .completed : .stale
        case .partial:
            return .partial
        case .failed:
            return .failed
        case .interrupted:
            return .interrupted
        case .commitFailed:
            return .commitFailed
        case .stale:
            return .stale
        }
    }

    static func hasCompleteManagedArtifacts(
        _ target: TargetRecord,
        artifactExists: ArtifactExistence
    ) -> Bool {
        guard !target.artifacts.isEmpty else {
            return false
        }

        var hasGeneratedHeaderOrInterface = false
        for artifact in target.artifacts {
            guard artifactExists(artifact) else {
                return false
            }
            if isGeneratedHeaderOrInterface(artifact) {
                hasGeneratedHeaderOrInterface = true
            }
        }
        return hasGeneratedHeaderOrInterface
    }

    static func isGeneratedHeaderOrInterface(_ artifact: ArtifactPath) -> Bool {
        artifact.rawValue.hasSuffix(".h") || artifact.rawValue.hasSuffix(".swiftinterface")
    }

    static func manifestTargetsByID(_ targets: [TargetRecord]) -> [String: TargetRecord] {
        var targetsByID: [String: TargetRecord] = [:]
        for target in targets {
            targetsByID[target.id] = target
        }
        return targetsByID
    }

    static func normalizedTargetIDs(_ targetIDs: [String]) -> [String] {
        Array(Set(targetIDs)).sorted()
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
