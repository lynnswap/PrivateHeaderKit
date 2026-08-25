import Foundation
import PrivateHeaderKitHelperProtocol
import PrivateHeaderKitTooling

struct RawHelperFailureCapsule: Equatable, Sendable {
    static let maximumLineCount = BoundedProcessOutput.maximumRenderedLineCount + 1
    static let maximumRenderedByteCount = 24 * 1_024

    enum HandshakeObservation: Equatable, Sendable {
        case available(PrivateHeaderKitRawDumpProcessHandshake)
        case missing
        case invalid
    }

    let text: String

    init(
        processResult: StreamingCommandResult,
        handshake: HandshakeObservation,
        recognizesSimulatorChildTermination: Bool
    ) {
        var diagnosticLines = processResult.emittedOutput.lines
        let reportedChildSignal: Int32?
        if recognizesSimulatorChildTermination,
           !processResult.wasKilled,
           let finalLine = diagnosticLines.last,
           let signal = Self.simulatorChildTerminationSignal(in: finalLine),
           signal == processResult.status
        {
            reportedChildSignal = signal
            diagnosticLines.removeLast()
        } else {
            reportedChildSignal = nil
        }
        if diagnosticLines.isEmpty {
            diagnosticLines = ["helper diagnostic output: none emitted"]
        }

        let termination: String
        if let reportedChildSignal {
            termination = "child_signal(\(reportedChildSignal))"
        } else if processResult.wasKilled {
            termination = "wrapper_signal(\(processResult.status))"
        } else {
            termination = "exit(\(processResult.status))"
        }

        let identity: String
        switch handshake {
        case .available(let value):
            identity = [
                "handshake=available",
                "helper=\(value.executableName)",
                "lc_uuid=\(value.executableMachOUUID.uuidString.lowercased())",
                "pid=\(value.processIdentifier)",
                "start_us=\(value.helperStartedAtUnixMicroseconds)",
            ].joined(separator: " ")
        case .missing:
            identity = "identity=unavailable handshake=missing"
        case .invalid:
            identity = "identity=unavailable handshake=invalid"
        }

        let terminationObservedAt = processResult
            .terminationObservedAtUnixEpochMicroseconds
            .map(String.init)
            ?? "unavailable"
        let headline = [
            "privateheaderkit raw helper error:",
            "capsule=v1",
            "termination=\(termination)",
            "wrapper_status=\(processResult.status)",
            "wrapper_killed=\(processResult.wasKilled)",
            identity,
            "termination_observed_us=\(terminationObservedAt)",
        ].joined(separator: " ")
        let text = (diagnosticLines + [headline]).joined(separator: "\n")
        precondition(
            diagnosticLines.count + 1 <= Self.maximumLineCount,
            "RawHelperFailureCapsule must enforce its rendered line-count bound"
        )
        precondition(
            text.utf8.count <= Self.maximumRenderedByteCount,
            "RawHelperFailureCapsule must enforce its rendered byte-count bound"
        )
        self.text = text
    }

    private static func simulatorChildTerminationSignal(in line: String) -> Int32? {
        let prefix = "Child process terminated with signal "
        guard line.hasPrefix(prefix) else { return nil }
        let suffix = line.dropFirst(prefix.count)
        guard let separator = suffix.firstIndex(of: ":") else { return nil }
        let signalText = suffix[..<separator]
        guard !signalText.isEmpty,
              signalText.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              let signal = Int32(String(signalText)),
              signal > 0
        else {
            return nil
        }
        let space = suffix.index(after: separator)
        guard space < suffix.endIndex,
              suffix[space] == " "
        else {
            return nil
        }
        let reasonStart = suffix.index(after: space)
        guard reasonStart < suffix.endIndex else { return nil }
        let reason = suffix[reasonStart...]
        guard !reason.hasPrefix(" "),
              !reason.hasSuffix(" "),
              line == prefix + String(signal) + ": " + String(reason)
        else {
            return nil
        }
        return signal
    }
}
