import Dispatch
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

typealias PrivateHeaderKitInputReader = @Sendable () async throws -> String?
typealias PrivateHeaderKitInputFinalizer = @Sendable () async throws -> Void

enum PrivateHeaderKitInputError: Error, Equatable, CustomStringConvertible, Sendable {
    case duplicateFailed(code: Int32)
    case terminalReadFailed(code: Int32)
    case terminalRawModeFailed(code: Int32)
    case terminalRestoreFailed(code: Int32)
    case descriptorFlagsFailed(operation: String, code: Int32)
    case readFailed(code: Int32)

    var description: String {
        switch self {
        case .duplicateFailed(let code): "unable to duplicate stdin (errno \(code))"
        case .terminalReadFailed(let code): "unable to read terminal mode (errno \(code))"
        case .terminalRawModeFailed(let code): "unable to enter raw terminal mode (errno \(code))"
        case .terminalRestoreFailed(let code): "unable to restore terminal mode (errno \(code))"
        case .descriptorFlagsFailed(let operation, let code):
            "unable to \(operation) stdin descriptor flags (errno \(code))"
        case .readFailed(let code): "unable to read stdin (errno \(code))"
        }
    }
}

typealias PrivateHeaderKitTerminalRestoration = @Sendable () throws -> Void
typealias PrivateHeaderKitInputEchoWriter = @Sendable (Data) -> Void

protocol PrivateHeaderKitTerminalModeControlling: Sendable {
    func enterRawMode(fileDescriptor: Int32) throws -> PrivateHeaderKitTerminalRestoration
}

struct PrivateHeaderKitSystemTerminalModeController: PrivateHeaderKitTerminalModeControlling {
    func enterRawMode(fileDescriptor: Int32) throws -> PrivateHeaderKitTerminalRestoration {
#if canImport(Darwin) || canImport(Glibc)
        var original = termios()
        guard tcgetattr(fileDescriptor, &original) == 0 else {
            throw PrivateHeaderKitInputError.terminalReadFailed(code: errno)
        }
        var raw = original
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
        withUnsafeMutableBytes(of: &raw.c_cc) { bytes in
            bytes[Int(VMIN)] = 1
            bytes[Int(VTIME)] = 0
        }
        // Input typed before the prompt belongs to preflight, where the terminal has already
        // echoed it. Discard that pending input instead of echoing it again in raw mode.
        guard tcsetattr(fileDescriptor, TCSAFLUSH, &raw) == 0 else {
            throw PrivateHeaderKitInputError.terminalRawModeFailed(code: errno)
        }
        let snapshot = PrivateHeaderKitTermiosSnapshot(
            fileDescriptor: fileDescriptor,
            value: original
        )
        return { try snapshot.restore() }
#else
        throw PrivateHeaderKitInputError.terminalRawModeFailed(code: ENOTSUP)
#endif
    }
}

#if canImport(Darwin) || canImport(Glibc)
private final class PrivateHeaderKitTermiosSnapshot: @unchecked Sendable {
    private let fileDescriptor: Int32
    private var value: termios

    init(fileDescriptor: Int32, value: termios) {
        self.fileDescriptor = fileDescriptor
        self.value = value
    }

    func restore() throws {
        guard tcsetattr(fileDescriptor, TCSANOW, &value) == 0 else {
            throw PrivateHeaderKitInputError.terminalRestoreFailed(code: errno)
        }
    }
}
#endif

final class PrivateHeaderKitAsyncInput: @unchecked Sendable {
    private let coordinator: PrivateHeaderKitInputCoordinator
    private let lifecycle: PrivateHeaderKitInputLifecycle
    private let sourceQueue: DispatchQueue
    private let usesTerminalMode: Bool

    init(
        fileDescriptor: Int32 = STDIN_FILENO,
        isTerminal: @escaping @Sendable (Int32) -> Bool = { isatty($0) != 0 },
        terminalModeController: any PrivateHeaderKitTerminalModeControlling =
            PrivateHeaderKitSystemTerminalModeController(),
        echoWriter: @escaping PrivateHeaderKitInputEchoWriter = {
            FileHandle.standardOutput.write($0)
        }
    ) throws {
        let readFileDescriptor = dup(fileDescriptor)
        guard readFileDescriptor >= 0 else {
            throw PrivateHeaderKitInputError.duplicateFailed(code: errno)
        }
        let originalStatusFlags = fcntl(readFileDescriptor, F_GETFL)
        guard originalStatusFlags >= 0 else {
            let code = errno
            _ = close(readFileDescriptor)
            throw PrivateHeaderKitInputError.descriptorFlagsFailed(
                operation: "read",
                code: code
            )
        }
        guard fcntl(readFileDescriptor, F_SETFL, originalStatusFlags | O_NONBLOCK) == 0 else {
            let code = errno
            _ = close(readFileDescriptor)
            throw PrivateHeaderKitInputError.descriptorFlagsFailed(
                operation: "enable nonblocking mode for",
                code: code
            )
        }

        let coordinator = PrivateHeaderKitInputCoordinator()
        let sourceQueue = DispatchQueue(label: "PrivateHeaderKit.stdin")
        let usesTerminalMode = isTerminal(fileDescriptor)
        self.coordinator = coordinator
        self.sourceQueue = sourceQueue
        self.usesTerminalMode = usesTerminalMode
        let lifecycle = PrivateHeaderKitInputLifecycle(
            coordinator: coordinator,
            readFileDescriptor: readFileDescriptor,
            originalStatusFlags: originalStatusFlags,
            usesTerminalMode: usesTerminalMode,
            terminalModeController: terminalModeController
        )
        self.lifecycle = lifecycle

        let source = DispatchSource.makeReadSource(
            fileDescriptor: readFileDescriptor,
            queue: sourceQueue
        )
        let buffer = PrivateHeaderKitInputBuffer(
            coordinator: coordinator,
            echoWriter: echoWriter
        )
        source.setEventHandler { [weak lifecycle] in
            guard let lifecycle else { return }
            let byteCount = max(1, min(Int(source.data), 4096))
            switch lifecycle.readChunk(maximumByteCount: byteCount) {
            case .data(let bytes, let wasReadInRawMode):
                buffer.consume(
                    bytes[...],
                    wasReadInRawMode: wasReadInRawMode,
                    lifecycle: lifecycle
                )
            case .eof:
                buffer.finish()
                try? lifecycle.finishEOF()
            case .retry:
                break
            case .failure(let code):
                try? lifecycle.fail(PrivateHeaderKitInputError.readFailed(code: code))
            }
        }
        source.setCancelHandler {
            _ = close(readFileDescriptor)
        }
        lifecycle.attach(source: source)
        source.resume()
    }

    deinit {
        try? lifecycle.cancel()
    }

    func readLine() async throws -> String? {
        try Task.checkCancellation()
        do {
            try sourceQueue.sync {
                if usesTerminalMode {
                    coordinator.discardBufferedLines()
                }
                try lifecycle.beginReading()
            }
        } catch {
            try? lifecycle.fail(error)
            throw error
        }
        do {
            let line = try await withTaskCancellationHandler {
                try await coordinator.next()
            } onCancel: {
                try? lifecycle.cancel()
            }
            try lifecycle.endReading()
            try Task.checkCancellation()
            return line
        } catch let operationError {
            do {
                try lifecycle.endReading()
            } catch {
                throw error
            }
            throw operationError
        }
    }

    func cancel() throws {
        try lifecycle.cancel()
    }

    func finish() throws {
        try lifecycle.finishEOF()
    }
}

actor PrivateHeaderKitInputSession {
    private var input: PrivateHeaderKitAsyncInput?
    private var isFinished = false

    func readLine() async throws -> String? {
        guard !isFinished else { return nil }
        let input: PrivateHeaderKitAsyncInput
        if let current = self.input {
            input = current
        } else {
            let created = try PrivateHeaderKitAsyncInput()
            self.input = created
            input = created
        }
        return try await input.readLine()
    }

    func finish() throws {
        guard !isFinished else { return }
        isFinished = true
        try input?.finish()
    }
}

final class PrivateHeaderKitInputCoordinator: @unchecked Sendable {
    private enum Completion {
        case eof
        case failure(any Error)
    }

    private let lock = NSLock()
    private var bufferedLines: [String] = []
    private var waiter: CheckedContinuation<String?, any Error>?
    private var completion: Completion?

    func next() async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            register(continuation)
        }
    }

    private func register(_ continuation: CheckedContinuation<String?, any Error>) {
        lock.lock()
        if !bufferedLines.isEmpty {
            let line = bufferedLines.removeFirst()
            lock.unlock()
            continuation.resume(returning: line)
            return
        }
        if let completion {
            lock.unlock()
            resume(continuation, with: completion)
            return
        }
        precondition(waiter == nil, "PrivateHeaderKit input supports one pending read")
        waiter = continuation
        lock.unlock()
    }

    func yield(_ line: String) {
        lock.lock()
        guard completion == nil else {
            lock.unlock()
            return
        }
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: line)
        } else {
            bufferedLines.append(line)
            lock.unlock()
        }
    }

    func discardBufferedLines() {
        lock.lock()
        precondition(waiter == nil, "prompt input can only be discarded before awaiting a line")
        bufferedLines.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    func finishEOF() {
        finish(with: .eof)
    }

    func fail(_ error: any Error) {
        finish(with: .failure(error))
    }

    private func finish(with completion: Completion) {
        lock.lock()
        guard self.completion == nil else {
            lock.unlock()
            return
        }
        self.completion = completion
        let waiter = waiter
        self.waiter = nil
        let shouldResume: Bool
        switch completion {
        case .eof:
            shouldResume = bufferedLines.isEmpty
        case .failure:
            bufferedLines.removeAll(keepingCapacity: false)
            shouldResume = true
        }
        lock.unlock()
        if shouldResume, let waiter {
            resume(waiter, with: completion)
        }
    }

    private func resume(
        _ continuation: CheckedContinuation<String?, any Error>,
        with completion: Completion
    ) {
        switch completion {
        case .eof:
            continuation.resume(returning: nil)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

final class PrivateHeaderKitInputLifecycle: @unchecked Sendable {
    private enum Completion {
        case eof
        case failure(any Error)
    }

    private let lock = NSLock()
    private let coordinator: PrivateHeaderKitInputCoordinator
    private let readFileDescriptor: Int32
    private let originalStatusFlags: Int32
    private let usesTerminalMode: Bool
    private let terminalModeController: any PrivateHeaderKitTerminalModeControlling
    private var restoreTerminal: PrivateHeaderKitTerminalRestoration?
    private var source: DispatchSourceRead?
    private var stopped = false
    private var mustRestoreStatusFlags = true
    private var cleanupError: (any Error)?

    init(
        coordinator: PrivateHeaderKitInputCoordinator,
        readFileDescriptor: Int32,
        originalStatusFlags: Int32,
        usesTerminalMode: Bool,
        terminalModeController: any PrivateHeaderKitTerminalModeControlling
    ) {
        self.coordinator = coordinator
        self.readFileDescriptor = readFileDescriptor
        self.originalStatusFlags = originalStatusFlags
        self.usesTerminalMode = usesTerminalMode
        self.terminalModeController = terminalModeController
    }

    func beginReading() throws {
        lock.lock()
        guard !stopped else {
            let cleanupError = self.cleanupError
            lock.unlock()
            if let cleanupError { throw cleanupError }
            return
        }
        precondition(restoreTerminal == nil, "terminal input already has an active read")
        guard usesTerminalMode else {
            lock.unlock()
            return
        }
        do {
            restoreTerminal = try terminalModeController.enterRawMode(
                fileDescriptor: readFileDescriptor
            )
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
    }

    func endReading() throws {
        lock.lock()
        guard !stopped else {
            let cleanupError = self.cleanupError
            lock.unlock()
            if let cleanupError { throw cleanupError }
            return
        }
        do {
            try restoreTerminal?()
            restoreTerminal = nil
            lock.unlock()
        } catch {
            restoreTerminal = nil
            cleanupError = error
            lock.unlock()
            try? stop(with: .failure(error))
            throw error
        }
    }

    fileprivate func readChunk(maximumByteCount: Int) -> PrivateHeaderKitInputReadResult {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return .retry
        }
        let wasReadInRawMode = restoreTerminal != nil
        var bytes = [UInt8](repeating: 0, count: maximumByteCount)
#if canImport(Darwin)
        let count = Darwin.read(readFileDescriptor, &bytes, maximumByteCount)
#elseif canImport(Glibc)
        let count = Glibc.read(readFileDescriptor, &bytes, maximumByteCount)
#else
        let count = -1
#endif
        let errorCode = errno
        lock.unlock()

        if count > 0 {
            return .data(Array(bytes.prefix(count)), wasReadInRawMode: wasReadInRawMode)
        }
        if count == 0 { return .eof }
        if errorCode == EINTR || errorCode == EAGAIN || errorCode == EWOULDBLOCK {
            return .retry
        }
        return .failure(code: errorCode)
    }

    func attach(source: DispatchSourceRead) {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            source.cancel()
            return
        }
        self.source = source
        lock.unlock()
    }

    func finishEOF() throws {
        try stop(with: .eof)
    }

    func fail(_ error: any Error) throws {
        try stop(with: .failure(error))
    }

    func cancel() throws {
        try stop(with: .failure(CancellationError()))
    }

    private func stop(with completion: Completion) throws {
        lock.lock()
        guard !stopped else {
            let cleanupError = self.cleanupError
            lock.unlock()
            if let cleanupError { throw cleanupError }
            return
        }
        stopped = true
        let source = source
        self.source = nil
        let restoreTerminal = restoreTerminal
        self.restoreTerminal = nil
        let mustRestoreStatusFlags = mustRestoreStatusFlags
        self.mustRestoreStatusFlags = false
        lock.unlock()

        var cleanupFailure: (any Error)?
        do {
            try restoreTerminal?()
        } catch {
            cleanupFailure = error
        }
        if mustRestoreStatusFlags,
           fcntl(readFileDescriptor, F_SETFL, originalStatusFlags) != 0,
           cleanupFailure == nil {
            cleanupFailure = PrivateHeaderKitInputError.descriptorFlagsFailed(
                operation: "restore",
                code: errno
            )
        }
        if let cleanupFailure {
            lock.lock()
            cleanupError = cleanupFailure
            lock.unlock()
            coordinator.fail(cleanupFailure)
        } else {
            switch completion {
            case .eof:
                coordinator.finishEOF()
            case .failure(let error):
                coordinator.fail(error)
            }
        }
        source?.cancel()
        if source == nil {
            _ = close(readFileDescriptor)
        }
        if let cleanupFailure { throw cleanupFailure }
    }
}

private enum PrivateHeaderKitInputReadResult {
    case data([UInt8], wasReadInRawMode: Bool)
    case eof
    case retry
    case failure(code: Int32)
}

final class PrivateHeaderKitInputBuffer: @unchecked Sendable {
    private var bytes: [UInt8] = []
    private var previousWasCarriageReturn = false
    private let coordinator: PrivateHeaderKitInputCoordinator
    private let echoWriter: PrivateHeaderKitInputEchoWriter

    init(
        coordinator: PrivateHeaderKitInputCoordinator,
        echoWriter: @escaping PrivateHeaderKitInputEchoWriter
    ) {
        self.coordinator = coordinator
        self.echoWriter = echoWriter
    }

    func consume(
        _ input: ArraySlice<UInt8>,
        wasReadInRawMode: Bool,
        lifecycle: PrivateHeaderKitInputLifecycle
    ) {
        if input.contains(3) {
            echo("^C\n", enabled: wasReadInRawMode)
            try? lifecycle.cancel()
            return
        }
        for byte in input {
            if previousWasCarriageReturn, byte == 10 {
                previousWasCarriageReturn = false
                continue
            }
            previousWasCarriageReturn = false
            switch byte {
            case 3:
                preconditionFailure("Ctrl-C is handled before line delivery")
            case 4:
                if !bytes.isEmpty {
                    echo("\n", enabled: wasReadInRawMode)
                    emitLine()
                }
                try? lifecycle.finishEOF()
                return
            case 10, 13:
                previousWasCarriageReturn = byte == 13
                echo("\n", enabled: wasReadInRawMode)
                emitLine()
            case 27:
                bytes.removeAll(keepingCapacity: true)
                echo("\n", enabled: wasReadInRawMode)
                coordinator.yield("\u{001B}")
                return
            case 8, 127:
                guard !bytes.isEmpty else { continue }
                bytes.removeLast()
                echo("\u{8} \u{8}", enabled: wasReadInRawMode)
            default:
                bytes.append(byte)
                if wasReadInRawMode {
                    echoWriter(Data([byte]))
                }
            }
        }
    }

    func finish() {
        if !bytes.isEmpty {
            emitLine()
        }
    }

    private func emitLine() {
        coordinator.yield(String(decoding: bytes, as: UTF8.self))
        bytes.removeAll(keepingCapacity: true)
    }

    private func echo(_ value: String, enabled: Bool) {
        guard enabled else { return }
        echoWriter(Data(value.utf8))
    }
}
