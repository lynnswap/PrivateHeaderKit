import Dispatch
import Foundation
import MachOSwiftSection
import SwiftDeclaration
import SwiftDeclarationRendering
import SwiftInterface

func withSilencedStdout<T>(_ enabled: Bool, _ body: () async throws -> T) async rethrows -> T {
    guard enabled else { return try await body() }
    let stdoutFD = fileno(stdout)
    let saved = dup(stdoutFD)
    if saved == -1 {
        return try await body()
    }
    let devNull = open("/dev/null", O_WRONLY)
    if devNull == -1 {
        close(saved)
        return try await body()
    }
    fflush(stdout)
    dup2(devNull, stdoutFD)
    close(devNull)
    defer {
        fflush(stdout)
        dup2(saved, stdoutFD)
        close(saved)
    }
    return try await body()
}

@inline(__always)
func profileNowNanoseconds(enabled: Bool) -> UInt64 {
    guard enabled else { return 0 }
    return DispatchTime.now().uptimeNanoseconds
}

func profileLogDuration(
    enabled: Bool,
    imagePath: String,
    name: String,
    since start: UInt64
) {
    guard enabled, start != 0 else { return }
    let end = DispatchTime.now().uptimeNanoseconds
    let delta = end &- start
    let seconds = Double(delta) / 1_000_000_000.0
    // Intentionally stderr so `withSilencedStdout` doesn't hide it.
    let secondsText = String(format: "%.3fs", seconds)
    fputs("privateheaderkit __raw-dump: profile \(name) \(secondsText) \(imagePath)\n", stderr)
}

final class SwiftInterfaceTimingHandler: SwiftIndexEvents.Handler {
    private struct OpKey: Hashable {
        let phase: SwiftIndexEvents.Phase
        let operation: SwiftIndexEvents.PhaseOperation
    }

    private let label: String
    private let startNanos: UInt64
    private let lock = NSLock()
    private var phaseStart: [SwiftIndexEvents.Phase: [UInt64]] = [:]
    private var opStart: [OpKey: UInt64] = [:]
    private var extractionSectionStart: [SwiftIndexEvents.Section: UInt64] = [:]

    init(label: String) {
        self.label = label
        self.startNanos = DispatchTime.now().uptimeNanoseconds
    }

    func handle(event: SwiftIndexEvents.Payload) {
        switch event {
        case .phaseTransition(let phase, let state):
            handlePhaseTransition(phase: phase, state: state)
        case .extractionStarted(section: let section):
            handleExtractionStarted(section: section)
        case .extractionCompleted(result: let result):
            handleExtractionCompleted(result: result)
        case .extractionFailed(section: let section, error: let error):
            handleExtractionFailed(section: section, error: error)
        case .phaseOperationStarted(let phase, let operation):
            handleOpStarted(phase: phase, operation: operation)
        case .phaseOperationCompleted(let phase, let operation):
            handleOpCompleted(phase: phase, operation: operation)
        case .phaseOperationFailed(let phase, let operation, let error):
            handleOpFailed(phase: phase, operation: operation, error: error)
        case .moduleCollectionStarted:
            handlePhaseTransition(phase: .moduleCollection, state: .started)
        case .moduleCollectionCompleted(result: _):
            handlePhaseTransition(phase: .moduleCollection, state: .completed)
        default:
            break
        }
    }

    private func handlePhaseTransition(phase: SwiftIndexEvents.Phase, state: SwiftIndexEvents.State) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        defer { lock.unlock() }

        switch state {
        case .started:
            phaseStart[phase, default: []].append(now)
            log(now: now, message: "\(phaseName(phase)) started")
        case .completed:
            let start = popPhaseStart(for: phase) ?? now
            log(now: now, message: "\(phaseName(phase)) completed (\(formatDurationSeconds(now &- start)))")
        case .failed(let error):
            let start = popPhaseStart(for: phase) ?? now
            log(now: now, message: "\(phaseName(phase)) failed (\(formatDurationSeconds(now &- start))): \(String(describing: error))")
        }
    }

    private func popPhaseStart(for phase: SwiftIndexEvents.Phase) -> UInt64? {
        guard var starts = phaseStart[phase], let start = starts.popLast() else {
            return nil
        }
        if starts.isEmpty {
            phaseStart.removeValue(forKey: phase)
        } else {
            phaseStart[phase] = starts
        }
        return start
    }

    private func handleOpStarted(phase: SwiftIndexEvents.Phase, operation: SwiftIndexEvents.PhaseOperation) {
        let now = DispatchTime.now().uptimeNanoseconds
        let key = OpKey(phase: phase, operation: operation)
        lock.lock()
        opStart[key] = now
        log(now: now, message: "\(phaseName(phase)).\(operationName(operation)) started")
        lock.unlock()
    }

    private func handleOpCompleted(phase: SwiftIndexEvents.Phase, operation: SwiftIndexEvents.PhaseOperation) {
        let now = DispatchTime.now().uptimeNanoseconds
        let key = OpKey(phase: phase, operation: operation)
        lock.lock()
        let start = opStart.removeValue(forKey: key) ?? now
        log(now: now, message: "\(phaseName(phase)).\(operationName(operation)) completed (\(formatDurationSeconds(now &- start)))")
        lock.unlock()
    }

    private func handleOpFailed(phase: SwiftIndexEvents.Phase, operation: SwiftIndexEvents.PhaseOperation, error: any Error) {
        let now = DispatchTime.now().uptimeNanoseconds
        let key = OpKey(phase: phase, operation: operation)
        lock.lock()
        let start = opStart.removeValue(forKey: key) ?? now
        log(now: now, message: "\(phaseName(phase)).\(operationName(operation)) failed (\(formatDurationSeconds(now &- start))): \(String(describing: error))")
        lock.unlock()
    }

    private func handleExtractionStarted(section: SwiftIndexEvents.Section) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        extractionSectionStart[section] = now
        log(now: now, message: "extraction.\(sectionName(section)) started")
        lock.unlock()
    }

    private func handleExtractionCompleted(result: SwiftIndexEvents.ExtractionResult) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let start = extractionSectionStart.removeValue(forKey: result.section) ?? now
        log(
            now: now,
            message: "extraction.\(sectionName(result.section)) completed (\(formatDurationSeconds(now &- start))) count=\(result.count)"
        )
        lock.unlock()
    }

    private func handleExtractionFailed(section: SwiftIndexEvents.Section, error: any Error) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let start = extractionSectionStart.removeValue(forKey: section) ?? now
        log(
            now: now,
            message: "extraction.\(sectionName(section)) failed (\(formatDurationSeconds(now &- start))): \(String(describing: error))"
        )
        lock.unlock()
    }

    private func log(now: UInt64, message: String) {
        let rel = formatDurationSeconds(now &- startNanos)
        fputs("privateheaderkit __raw-dump: swift-events [\(label)] +\(rel) \(message)\n", stderr)
    }

    private func formatDurationSeconds(_ nanos: UInt64) -> String {
        String(format: "%.3fs", Double(nanos) / 1_000_000_000.0)
    }

    private func phaseName(_ phase: SwiftIndexEvents.Phase) -> String {
        switch phase {
        case .preparation: return "preparation"
        case .extraction: return "extraction"
        case .indexing: return "indexing"
        case .moduleCollection: return "moduleCollection"
        case .build: return "build"
        }
    }

    private func operationName(_ op: SwiftIndexEvents.PhaseOperation) -> String {
        switch op {
        case .typeIndexing: return "typeIndexing"
        case .protocolIndexing: return "protocolIndexing"
        case .conformanceIndexing: return "conformanceIndexing"
        case .extensionIndexing: return "extensionIndexing"
        }
    }

    private func sectionName(_ section: SwiftIndexEvents.Section) -> String {
        switch section {
        case .swiftTypes: return "swiftTypes"
        case .swiftProtocols: return "swiftProtocols"
        case .protocolConformances: return "protocolConformances"
        case .associatedTypes: return "associatedTypes"
        case .symbolIndex: return "symbolIndex"
        }
    }
}
