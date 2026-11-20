import Foundation
import PrivateHeaderKitCore
import PrivateHeaderKitTooling

/// The Simulator runtime and device a generation runs in.
struct SimulatorResolution: Equatable, Sendable {
    let runtimeVersion: String
    let runtimeBuild: String
    let runtimeIdentifier: String
    let resolvedRuntimeRoot: String
    let metadataIsSeed: Bool
    let deviceName: String
    let deviceUDID: String
    let deviceOwnership: SimulatorDeviceOwnership

    init(
        runtimeVersion: String,
        runtimeBuild: String,
        runtimeIdentifier: String,
        resolvedRuntimeRoot: String,
        metadataIsSeed: Bool,
        deviceName: String,
        deviceUDID: String,
        deviceOwnership: SimulatorDeviceOwnership = .borrowed
    ) {
        self.runtimeVersion = runtimeVersion
        self.runtimeBuild = runtimeBuild
        self.runtimeIdentifier = runtimeIdentifier
        self.resolvedRuntimeRoot = resolvedRuntimeRoot
        self.metadataIsSeed = metadataIsSeed
        self.deviceName = deviceName
        self.deviceUDID = deviceUDID
        self.deviceOwnership = deviceOwnership
    }

    init(runtime: RuntimeInfo, metadataIsSeed: Bool, resolvedDevice: ResolvedSimulatorDevice) {
        self.init(
            runtimeVersion: runtime.version,
            runtimeBuild: runtime.build,
            runtimeIdentifier: runtime.identifier,
            resolvedRuntimeRoot: runtime.runtimeRoot,
            metadataIsSeed: metadataIsSeed,
            deviceName: resolvedDevice.device.name,
            deviceUDID: resolvedDevice.device.udid,
            deviceOwnership: resolvedDevice.ownership
        )
    }
}

/// Resolves the Simulator a generation runs in and deletes the device again when the CLI
/// created it for this run.
struct SimulatorSession: Sendable {
    let processRunner: any CommandRunning
    let console: Console

    /// Runs `operation` with the Simulator that `options` selects, or with `nil` for macOS.
    func run<Result>(
        for options: GenerateCommand.Options,
        operation: (SimulatorResolution?) async throws -> Result
    ) async throws -> Result {
        let resolution: SimulatorResolution?
        if options.platform.simulatorPlatform == nil {
            resolution = nil
        } else {
            renderPrivateHeaderKitSimulatorPreparation(options, outputLogger: console.output)
            let resolved = try await Self.resolve(for: options, processRunner: processRunner)
            renderPrivateHeaderKitSimulatorReady(
                resolved,
                command: options,
                outputLogger: console.output
            )
            resolution = resolved
        }

        let result: Result
        do {
            result = try await operation(resolution)
        } catch {
            let operationError = error
            if let resolution {
                do {
                    try await finish(resolution)
                } catch {
                    throw CleanupError(
                        deviceName: resolution.deviceName,
                        deviceUDID: resolution.deviceUDID,
                        operationError: String(describing: operationError),
                        cleanupError: String(describing: error)
                    )
                }
            }
            throw operationError
        }
        if let resolution {
            do {
                try await finish(resolution)
            } catch {
                throw CleanupError(
                    deviceName: resolution.deviceName,
                    deviceUDID: resolution.deviceUDID,
                    operationError: nil,
                    cleanupError: String(describing: error)
                )
            }
        }
        return result
    }

    struct CleanupError: Error, CustomStringConvertible {
        let deviceName: String
        let deviceUDID: String
        let operationError: String?
        let cleanupError: String

        var description: String {
            let device = "\(deviceName) (UDID: \(deviceUDID))"
            guard let operationError else {
                return "simulator cleanup failed for \(device): \(cleanupError)"
            }
            return "simulator cleanup failed for \(device) after \(operationError): \(cleanupError)"
        }
    }

    private func finish(_ resolution: SimulatorResolution) async throws {
        guard resolution.deviceOwnership == .runOwned else { return }
        let processRunner = processRunner
        // Detached so that a cancelled run still deletes the device it created.
        try await Task.detached {
            try await Simctl.deleteDevice(
                DeviceInfo(
                    name: resolution.deviceName,
                    udid: resolution.deviceUDID,
                    state: "Booted"
                ),
                runner: processRunner
            )
        }.value
        renderPrivateHeaderKitSimulatorCleanup(outputLogger: console.output)
    }

    /// Finds the runtime `options` names and a booted device in it, creating a device when
    /// `options` names none.
    static func resolve(
        for options: GenerateCommand.Options,
        processRunner: any CommandRunning,
        dedicatedDeviceName: String? = nil
    ) async throws -> SimulatorResolution {
        guard let simulatorPlatform = options.platform.simulatorPlatform else {
            throw PrivateHeaderKitCLIError.missingSimulatorResolution
        }
        let runtime = try await Simctl.findRuntime(
            platform: simulatorPlatform,
            version: options.version,
            build: options.build,
            runner: processRunner
        )
        let metadataIsSeed = try RuntimeReleaseMetadata.isSeed(
            in: canonicalDirectoryURL(path: runtime.runtimeRoot),
            layout: .simulator
        )
        _ = try PrivateHeaderGeneration.Source(
            platform: options.platform.corePlatform,
            version: runtime.version,
            build: runtime.build.isEmpty ? nil : runtime.build,
            metadataIsSeed: metadataIsSeed
        )
        let resolvedDevice = try await Simctl.resolveDevice(
            runtime: runtime,
            query: options.device,
            runner: processRunner,
            dedicatedDeviceName: dedicatedDeviceName
        )
        return SimulatorResolution(
            runtime: runtime,
            metadataIsSeed: metadataIsSeed,
            resolvedDevice: resolvedDevice
        )
    }
}
