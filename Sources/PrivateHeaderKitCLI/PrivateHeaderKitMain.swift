import Foundation

#if os(macOS)
import UnixSignals
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if os(macOS)
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
#endif

@main
struct PrivateHeaderKitMain {
    static func main() async {
        let arguments = CommandLine.arguments
        #if os(macOS)
        let signals = await UnixSignalsSequence(trapping: .sigint, .sigterm)
        let signalSource = PrivateHeaderKitUnixSignalSource(signals: signals)
        let status = await coordinatePrivateHeaderKitOperation(
            signalSource: signalSource,
            operation: {
                await runPrivateHeaderKitCommand(arguments)
            }
        )
        #else
        let status = await runPrivateHeaderKitCommand(arguments)
        #endif
        exit(status)
    }
}
