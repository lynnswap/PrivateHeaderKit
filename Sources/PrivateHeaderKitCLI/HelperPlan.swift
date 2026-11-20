import Foundation
import PrivateHeaderKitCore
import PrivateHeaderKitTooling

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The helper executables a generation uses and, when the CLI runs from a package checkout,
/// the builds that produce them.
struct HelperPlan: Sendable {
    let helperURLs: PrivateHeaderGeneration.RawDumping.HelperURLs
    private let buildInvocations: [BuildInvocation]

    private struct BuildInvocation: Sendable {
        let command: [String]
        let cwd: URL
    }

    /// Locates the helpers beside an installed CLI, or plans their builds when the CLI runs
    /// from a package checkout.
    ///
    /// The helpers report the build version compiled into them, and generation rejects a
    /// helper whose version differs from the CLI's.
    static func resolve(
        executableURL: URL,
        simulatorHelperPath: String?,
        simulatorPlatform: SimulatorPlatform?,
        processRunner: any CommandRunning,
        simulatorArchitecture: String = defaultSimulatorArchitecture()
    ) async throws -> HelperPlan {
        let explicitSimulatorURL = explicitSimulatorHelperURL(simulatorHelperPath)
        if let explicitSimulatorURL, simulatorPlatform != nil {
            try requireExecutableSimulatorHelper(explicitSimulatorURL)
        }
        guard let layout = swiftPMBuildProductLayout(for: executableURL) else {
            let hostURL = defaultRawDumpHelperURL(executableURL: executableURL)
            let simulatorURL = explicitSimulatorURL
                ?? defaultSimulatorHelperURL(
                    hostExecutableURL: hostURL,
                    platform: simulatorPlatform ?? .iOS
                )
            if simulatorPlatform != nil {
                try requireExecutableSimulatorHelper(simulatorURL)
            }
            return HelperPlan(
                helperURLs: .init(host: hostURL, simulator: simulatorURL),
                buildInvocations: []
            )
        }

        let hostCommand = [
            "swift", "build", "--force-resolved-versions", "-c", layout.configuration,
        ]
        let hostBinDirectory = try swiftPMBinDirectory(
            from: await processRunner.runCapture(
                hostCommand + ["--show-bin-path"],
                env: nil,
                cwd: layout.repoRoot
            ),
            destination: "host"
        )
        let hostURL = hostBinDirectory.appendingPathComponent(
            "privateheaderkit-raw-helper",
            isDirectory: false
        )
        var buildInvocations = [
            BuildInvocation(
                command: hostCommand + ["--product", "privateheaderkit-raw-helper"],
                cwd: layout.repoRoot
            )
        ]

        let simulatorURL: URL
        if let explicitSimulatorURL {
            simulatorURL = explicitSimulatorURL
        } else if let simulatorPlatform {
            let simulatorTriple = simulatorPlatform.swiftPMTriple(
                architecture: simulatorArchitecture
            )
            let sdkPath = try lastNonemptyOutputLine(
                await processRunner.runCapture(
                    ["xcrun", "--sdk", simulatorPlatform.sdkName, "--show-sdk-path"],
                    env: nil,
                    cwd: nil
                ),
                failureMessage: "failed to resolve \(simulatorPlatform.userFacingSimulatorName) SDK path"
            )
            let simulatorCommand = [
                "swift", "build", "--force-resolved-versions", "-c", layout.configuration,
                "--scratch-path",
                SwiftPMBuildPaths.simulatorScratchURL(
                    repoRoot: layout.repoRoot,
                    triple: simulatorTriple
                ).path,
                "--sdk", sdkPath,
                "--triple", simulatorTriple,
            ]
            simulatorURL = try swiftPMBinDirectory(
                from: await processRunner.runCapture(
                    simulatorCommand + ["--show-bin-path"],
                    env: nil,
                    cwd: layout.repoRoot
                ),
                destination: simulatorPlatform.userFacingSimulatorName
            ).appendingPathComponent("privateheaderkit-sim-helper", isDirectory: false)
            buildInvocations.append(
                BuildInvocation(
                    command: simulatorCommand + ["--product", "privateheaderkit-sim-helper"],
                    cwd: layout.repoRoot
                )
            )
        } else {
            simulatorURL = defaultSimulatorHelperURL(hostExecutableURL: hostURL, platform: .iOS)
        }
        return HelperPlan(
            helperURLs: .init(host: hostURL, simulator: simulatorURL),
            buildInvocations: buildInvocations
        )
    }

    /// Builds the helpers of a package checkout. An installed CLI has nothing to build.
    func buildHelpers(using processRunner: any CommandRunning) async throws {
        for invocation in buildInvocations {
            _ = try await processRunner.runCapture(
                invocation.command,
                env: nil,
                cwd: invocation.cwd
            )
        }
    }

    /// The architecture SwiftPM builds the Simulator helper for on this Mac.
    static func defaultSimulatorArchitecture() -> String {
    #if arch(x86_64)
        return currentHostSupportsNativeArm64Simulator() ? "arm64" : "x86_64"
    #else
        return "arm64"
    #endif
    }
}

private func defaultRawDumpHelperURL(executableURL: URL) -> URL {
    let cohortExecutable = executableURL.resolvingSymlinksInPath()
    return cohortExecutable.deletingLastPathComponent()
        .appendingPathComponent("privateheaderkit-raw-helper", isDirectory: false)
}

private func defaultSimulatorHelperURL(
    hostExecutableURL: URL,
    platform: SimulatorPlatform
) -> URL {
    let cohortHelper = hostExecutableURL.resolvingSymlinksInPath()
    return cohortHelper.deletingLastPathComponent()
        .appendingPathComponent(
            installedSimulatorHelperName(for: platform),
            isDirectory: false
        )
}

private func installedSimulatorHelperName(
    for platform: SimulatorPlatform
) -> String {
    switch platform {
    case .iOS:
        "privateheaderkit-sim-helper"
    case .watchOS:
        "privateheaderkit-watch-sim-helper"
    }
}

/// A Simulator helper is started through `simctl spawn`, which reports a helper it cannot
/// start as an ordinary nonzero exit. Checking the file first keeps a missing helper from
/// being recorded as one failure per target.
private func requireExecutableSimulatorHelper(_ url: URL) throws {
    guard Which.find(url.path) != nil else {
        throw ToolingError.message(
            "Simulator helper is missing or not an executable file: \(url.path)"
        )
    }
}

private struct SwiftPMBuildProductLayout {
    let buildRoot: URL
    let configuration: String

    var repoRoot: URL { buildRoot.deletingLastPathComponent() }
}

private func swiftPMBuildProductLayout(for executableURL: URL) -> SwiftPMBuildProductLayout? {
    let directory = executableURL.deletingLastPathComponent()
    let components = directory.pathComponents
    guard let buildIndex = components.lastIndex(of: ".build") else {
        return nil
    }
    let trailing = Array(components.dropFirst(buildIndex + 1))
    let configuration: String?
    switch trailing.count {
    case 1:
        configuration = swiftPMBuildConfiguration(trailing[0])
    case 2:
        configuration = swiftPMBuildConfiguration(trailing[1])
    case 3 where trailing[0] == "out" && trailing[1] == "Products":
        configuration = swiftPMBuildConfiguration(trailing[2])
    default:
        return nil
    }
    guard let configuration else { return nil }
    return SwiftPMBuildProductLayout(
        buildRoot: URL(
            fileURLWithPath: NSString.path(
                withComponents: Array(components.prefix(buildIndex + 1))
            )
        ),
        configuration: configuration
    )
}

private func swiftPMBuildConfiguration(_ value: String) -> String? {
    switch value.lowercased() {
    case "debug": "debug"
    case "release": "release"
    default: nil
    }
}

private func explicitSimulatorHelperURL(_ path: String?) -> URL? {
    path.map {
        URL(fileURLWithPath: PathUtils.expandTilde($0), isDirectory: false)
    }
}

private func swiftPMBinDirectory(from output: String, destination: String) throws -> URL {
    let path = try lastNonemptyOutputLine(
        output,
        failureMessage: "swift build --show-bin-path returned no path for \(destination)"
    )
    guard NSString(string: path).isAbsolutePath else {
        throw ToolingError.message(
            "swift build --show-bin-path returned a relative path for \(destination): \(path)"
        )
    }
    return URL(fileURLWithPath: path, isDirectory: true)
}

private func lastNonemptyOutputLine(_ output: String, failureMessage: String) throws -> String {
    guard let line = output
        .split(whereSeparator: \Character.isNewline)
        .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        .last(where: { !$0.isEmpty })
    else {
        throw ToolingError.message(failureMessage)
    }
    return line
}

private func currentHostSupportsNativeArm64Simulator() -> Bool {
#if canImport(Darwin)
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value != 0
#else
    return false
#endif
}
