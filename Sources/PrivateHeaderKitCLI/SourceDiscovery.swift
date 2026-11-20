import Foundation
import PrivateHeaderKitCore
import PrivateHeaderKitTooling

/// The sources the wizard offers: the available Simulator runtimes and this Mac.
struct SourceDiscovery: Equatable, Sendable {
    struct Source: Equatable, Sendable {
        let platform: GenerateCommand.Platform
        let version: String
        let build: String?
        let metadataIsSeed: Bool
        let systemRoot: String?

        init(
            platform: GenerateCommand.Platform,
            version: String,
            build: String?,
            metadataIsSeed: Bool = false,
            systemRoot: String?
        ) {
            self.platform = platform
            self.version = version
            self.build = build
            self.metadataIsSeed = metadataIsSeed
            self.systemRoot = systemRoot
        }

        var versionAndBuildDisplayName: String {
            PrivateHeaderGeneration.Source.versionAndBuildDisplayName(
                version: version,
                build: build,
                releaseChannel: metadataIsSeed ? .beta : .release
            )
        }

        var displayName: String {
            "\(platform.rawValue) \(versionAndBuildDisplayName)"
        }
    }

    struct Failure: Equatable, Sendable {
        let source: String
        let message: String

        var description: String { "\(source): \(message)" }
    }

    let sources: [Source]
    let failures: [Failure]

    init(sources: [Source], failures: [Failure] = []) {
        self.sources = sources
        self.failures = failures
    }

    /// Lists the available Simulator runtimes and this Mac. A source that cannot be read is
    /// reported as a failure and does not hide the others.
    static func discover(using processRunner: any CommandRunning) async throws -> SourceDiscovery {
        try Task.checkCancellation()
        var sources: [Source] = []
        var failures: [Failure] = []
        let runtimes: [RuntimeInfo]
        do {
            runtimes = try await Simctl.listRuntimes(runner: processRunner)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            failures.append(.init(source: "Simulator runtimes", message: String(describing: error)))
            runtimes = []
        }
        for runtime in runtimes {
            try Task.checkCancellation()
            do {
                let metadataIsSeed = try RuntimeReleaseMetadata.isSeed(
                    in: canonicalDirectoryURL(path: runtime.runtimeRoot),
                    layout: .simulator
                )
                sources.append(.init(
                    platform: .init(simulatorPlatform: runtime.platform),
                    version: runtime.version,
                    build: runtime.build.isEmpty ? nil : runtime.build,
                    metadataIsSeed: metadataIsSeed,
                    systemRoot: nil
                ))
            } catch {
                let build = runtime.build.isEmpty ? "" : " (\(runtime.build))"
                failures.append(.init(
                    source: "\(runtime.platform.userFacingSourceName) \(runtime.version)\(build)",
                    message: String(describing: error)
                ))
            }
        }
        try Task.checkCancellation()
        do {
            sources.append(try await currentMacOSSource(using: processRunner))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            failures.append(.init(source: "macOS", message: String(describing: error)))
        }
        try Task.checkCancellation()
        return .init(sources: sources, failures: failures)
    }

    private static func currentMacOSSource(
        using processRunner: any CommandRunning
    ) async throws -> Source {
        let version = try await processRunner.runCapture(
            ["/usr/bin/sw_vers", "-productVersion"],
            env: nil,
            cwd: nil
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let build = try await processRunner.runCapture(
            ["/usr/bin/sw_vers", "-buildVersion"],
            env: nil,
            cwd: nil
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let metadataIsSeed = try RuntimeReleaseMetadata.isSeed(
            in: URL(fileURLWithPath: "/", isDirectory: true),
            layout: .macOS
        )
        return Source(
            platform: .macOS,
            version: version,
            build: build.isEmpty ? nil : build,
            metadataIsSeed: metadataIsSeed,
            systemRoot: "/"
        )
    }
}
