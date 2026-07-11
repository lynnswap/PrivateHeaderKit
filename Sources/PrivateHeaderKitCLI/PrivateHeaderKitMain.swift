import Foundation
import UnixSignals

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private actor PrivateHeaderKitUnixSignalSource: PrivateHeaderKitSignalSource {
    private let nextSignalTask: Task<PrivateHeaderKitTerminationSignal?, Never>

    init(signals: UnixSignalsSequence) {
        nextSignalTask = Task {
            var iterator = signals.makeAsyncIterator()
            guard let signal = await iterator.next() else { return nil }
            if signal == .sigint { return .interrupt }
            if signal == .sigterm { return .terminate }
            preconditionFailure("received a Unix signal that was not registered")
        }
    }

    func next() async -> PrivateHeaderKitTerminationSignal? {
        let nextSignalTask = self.nextSignalTask
        return await withTaskCancellationHandler {
            await nextSignalTask.value
        } onCancel: {
            nextSignalTask.cancel()
        }
    }
}

@main
struct PrivateHeaderKitMain {
    static func main() async {
        let arguments = CommandLine.arguments
        let signals = await UnixSignalsSequence(trapping: .sigint, .sigterm)
        let signalSource = PrivateHeaderKitUnixSignalSource(signals: signals)
        let status = await coordinatePrivateHeaderKitOperation(
            signalSource: signalSource,
            operation: {
                await runPrivateHeaderKitCommand(arguments)
            }
        )
        exit(status)
    }
}
