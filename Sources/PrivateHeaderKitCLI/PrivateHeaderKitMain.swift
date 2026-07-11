import Foundation
import UnixSignals

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private struct PrivateHeaderKitUnixSignalSource: PrivateHeaderKitSignalSource {
    let signals: UnixSignalsSequence

    func next() async -> PrivateHeaderKitTerminationSignal? {
        var iterator = signals.makeAsyncIterator()
        guard let signal = await iterator.next() else { return nil }
        if signal == .sigint { return .interrupt }
        if signal == .sigterm { return .terminate }
        preconditionFailure("received a Unix signal that was not registered")
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
