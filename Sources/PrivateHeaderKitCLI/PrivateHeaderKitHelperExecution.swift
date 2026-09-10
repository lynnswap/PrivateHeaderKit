import Foundation
import PrivateHeaderKitCore
import PrivateHeaderKitTooling

struct PrivateHeaderKitHelperExecution: Sendable {
    let processRunner: any CommandRunning
    let recoveryReporter: PrivateHeaderKitOutputLogger

    func run<Output: Sendable>(
        executionMode: PrivateHeaderGeneration.RawDumping.ExecutionMode,
        isSuccessful: @Sendable (Output) -> Bool,
        prepareForRetry: @Sendable () throws -> Void = {},
        operation: @Sendable () async throws -> Output
    ) async throws -> Output {
        while true {
            try Task.checkCancellation()
            let outcome: Swift.Result<Output, any Error>
            do {
                outcome = .success(try await operation())
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                guard case .commandFailed = error as? ToolingError else { throw error }
                outcome = .failure(error)
            }
            try Task.checkCancellation()
            if case .success(let output) = outcome, isSuccessful(output) {
                return output
            }
            guard case .simulator(let deviceUDID, _, let runtime) = executionMode,
                  try await recoverSimulatorIfUnavailable(
                    deviceUDID: deviceUDID,
                    runtimeIdentifier: runtime.identifier
                  )
            else {
                return try outcome.get()
            }
            do {
                try Task.checkCancellation()
                try prepareForRetry()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw PrivateHeaderGeneration.RawDumping.ExecutionError
                    .retryPreparationFailed(String(describing: error))
            }
        }
    }

    private func recoverSimulatorIfUnavailable(
        deviceUDID: String,
        runtimeIdentifier: String
    ) async throws -> Bool {
        do {
            guard let device = try await Simctl.availableDevice(
                runtimeId: runtimeIdentifier,
                udid: deviceUDID,
                runner: processRunner
            ) else {
                throw ToolingError.message(
                    "device is no longer available in runtime \(runtimeIdentifier)"
                )
            }
            try Task.checkCancellation()
            switch device.state.lowercased() {
            case "booted":
                return false
            case "shutdown", "booting", "shutting down":
                break
            default:
                throw ToolingError.message("unexpected device state: \(device.state)")
            }
            recoveryReporter(
                "Simulator \(deviceUDID) is \(device.state). "
                    + "Waiting for it to restart before retrying."
            )
            _ = try await Simctl.ensureDeviceBooted(device, runner: processRunner, force: true)
            try Task.checkCancellation()
            recoveryReporter("Simulator \(deviceUDID) is ready; retrying the interrupted operation.")
            return true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            throw PrivateHeaderGeneration.RawDumping.ExecutionError.environmentUnavailable(
                "simulator \(deviceUDID): \(error)"
            )
        }
    }
}
