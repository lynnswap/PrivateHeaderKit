import Foundation

public extension PrivateHeaderGeneration {
    struct RunRepository: Sendable {
        public let stateDirectory: URL

        public init(stateDirectory: URL) {
            self.stateDirectory = stateDirectory
        }

        public init(plan: Plan) {
            self.init(stateDirectory: plan.stateDirectory)
        }

        public var manifestURL: URL {
            stateDirectory.appendingPathComponent("manifest.json", isDirectory: false)
        }

        public var runsDirectory: URL {
            stateDirectory.appendingPathComponent("runs", isDirectory: true)
        }

        public func runDirectory(for runID: String) throws -> URL {
            try Self.validateRunID(runID)
            return runsDirectory.appendingPathComponent(runID, isDirectory: true)
        }

        public func runRecordURL(for runID: String) throws -> URL {
            try runDirectory(for: runID).appendingPathComponent("run.json", isDirectory: false)
        }

        public func logsDirectory(for runID: String) throws -> URL {
            try runDirectory(for: runID).appendingPathComponent("logs", isDirectory: true)
        }

        public func stagingDirectory(for runID: String) throws -> URL {
            try runDirectory(for: runID).appendingPathComponent("staging", isDirectory: true)
        }

        public func prepareStateDirectory() throws {
            try FileManager.default.createDirectory(
                at: stateDirectory,
                withIntermediateDirectories: true
            )
        }

        @discardableResult
        public func prepareRunDirectories(for runID: String) throws -> RunDirectories {
            let runDirectory = try runDirectory(for: runID)
            let directories = RunDirectories(
                runDirectory: runDirectory,
                recordURL: runDirectory.appendingPathComponent("run.json", isDirectory: false),
                logsDirectory: runDirectory.appendingPathComponent("logs", isDirectory: true),
                stagingDirectory: runDirectory.appendingPathComponent("staging", isDirectory: true)
            )
            try FileManager.default.createDirectory(
                at: directories.logsDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: directories.stagingDirectory,
                withIntermediateDirectories: true
            )
            return directories
        }

        public func readManifest() throws -> Manifest? {
            try readIfPresent(Manifest.self, from: manifestURL)
        }

        public func writeManifest(_ manifest: Manifest) throws {
            try prepareStateDirectory()
            try StateJSON.write(manifest, to: manifestURL)
        }

        public func readRun(id runID: String) throws -> RunRecord? {
            try readIfPresent(RunRecord.self, from: runRecordURL(for: runID))
        }

        public func writeRun(_ run: RunRecord) throws {
            let directories = try prepareRunDirectories(for: run.runID)
            try StateJSON.write(run, to: directories.recordURL)
        }

        public func readLatestRun() throws -> RunRecord? {
            guard let manifest = try readManifest() else {
                return nil
            }
            return try readLatestRun(from: manifest)
        }

        public func readLatestRun(from manifest: Manifest) throws -> RunRecord? {
            guard let latestRunID = manifest.latestRunID else {
                return nil
            }
            return try readRun(id: latestRunID)
        }

        public func listRunSummaries() throws -> [RunSummary] {
            guard FileManager.default.fileExists(atPath: runsDirectory.path) else {
                return []
            }

            let contents = try FileManager.default.contentsOfDirectory(
                at: runsDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )

            var summaries: [RunSummary] = []
            for url in contents {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else {
                    continue
                }

                let runID = url.lastPathComponent
                try Self.validateRunID(runID)
                if let run = try readRun(id: runID) {
                    summaries.append(RunSummary(runID: runID, startedAt: run.startedAt))
                }
            }

            return summaries
        }

        @discardableResult
        public func pruneRunHistory(
            from runs: [RunSummary],
            limit: Int = 10
        ) throws -> RunPruneResult {
            try runs.forEach { try Self.validateRunID($0.runID) }

            let retainedRunIDs = RunHistoryRetention.retainedRunIDs(from: runs, limit: limit)
            let retained = Set(retainedRunIDs)
            let prunedRunIDs = try pruneRunDirectories(retaining: retained)

            return RunPruneResult(
                retainedRunIDs: retainedRunIDs,
                prunedRunIDs: prunedRunIDs
            )
        }
    }

    struct RunDirectories: Equatable, Sendable {
        public let runDirectory: URL
        public let recordURL: URL
        public let logsDirectory: URL
        public let stagingDirectory: URL

        public init(
            runDirectory: URL,
            recordURL: URL,
            logsDirectory: URL,
            stagingDirectory: URL
        ) {
            self.runDirectory = runDirectory
            self.recordURL = recordURL
            self.logsDirectory = logsDirectory
            self.stagingDirectory = stagingDirectory
        }
    }

    struct RunPruneResult: Equatable, Sendable {
        public let retainedRunIDs: [String]
        public let prunedRunIDs: [String]

        public init(retainedRunIDs: [String], prunedRunIDs: [String]) {
            self.retainedRunIDs = retainedRunIDs
            self.prunedRunIDs = prunedRunIDs
        }
    }

    enum RunRepositoryError: Error, Equatable, CustomStringConvertible, Sendable {
        case invalidRunID(String)

        public var description: String {
            switch self {
            case .invalidRunID(let runID):
                "run ID is not safe as a path component: \(runID)"
            }
        }
    }
}

private extension PrivateHeaderGeneration.RunRepository {
    func readIfPresent<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try PrivateHeaderGeneration.StateJSON.read(type, from: url)
    }

    func pruneRunDirectories(retaining retainedRunIDs: Set<String>) throws -> [String] {
        guard FileManager.default.fileExists(atPath: runsDirectory.path) else {
            return []
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: runsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )

        var prunedRunIDs: [String] = []
        for url in contents {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                continue
            }

            let runID = url.lastPathComponent
            try Self.validateRunID(runID)
            guard !retainedRunIDs.contains(runID) else {
                continue
            }

            try FileManager.default.removeItem(at: url)
            prunedRunIDs.append(runID)
        }

        return prunedRunIDs.sorted()
    }

    static func validateRunID(_ runID: String) throws {
        guard !runID.isEmpty,
              runID != ".",
              runID != "..",
              !runID.contains("/"),
              !runID.contains("\0")
        else {
            throw PrivateHeaderGeneration.RunRepositoryError.invalidRunID(runID)
        }
    }
}
