enum PrivateHeaderKitTerminationSignal: Equatable, Sendable {
    case interrupt
    case terminate

    var exitCode: Int32 {
        switch self {
        case .interrupt: 130
        case .terminate: 143
        }
    }
}

private enum PrivateHeaderKitSignalRaceEvent: Sendable {
    case operationFinished(Int32)
    case signalReceived(PrivateHeaderKitTerminationSignal)
    case signalSequenceFinished
}

protocol PrivateHeaderKitSignalSource: Sendable {
    func next() async -> PrivateHeaderKitTerminationSignal?
}

func coordinatePrivateHeaderKitOperation(
    signalSource: any PrivateHeaderKitSignalSource,
    operation: @escaping @Sendable () async -> Int32
) async -> Int32 {
    await withTaskGroup(of: PrivateHeaderKitSignalRaceEvent.self) { group in
        group.addTask {
            .operationFinished(await operation())
        }
        group.addTask {
            if let signal = await signalSource.next() {
                return .signalReceived(signal)
            }
            return .signalSequenceFinished
        }

        guard let first = await group.next() else {
            preconditionFailure("signal coordinator started without child operations")
        }
        switch first {
        case .operationFinished(let status):
            group.cancelAll()
            await group.waitForAll()
            return status

        case .signalReceived(let signal):
            group.cancelAll()
            // Cancellation is only a stop request. Do not return the signal status until the
            // command operation has completed subprocess teardown, Core interruption handling,
            // and interactive-input restoration.
            await group.waitForAll()
            return signal.exitCode

        case .signalSequenceFinished:
            while let event = await group.next() {
                if case .operationFinished(let status) = event {
                    return status
                }
            }
            return 130
        }
    }
}
