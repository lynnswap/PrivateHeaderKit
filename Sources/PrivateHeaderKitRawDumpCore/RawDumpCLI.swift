import Foundation
import MachOKit
import PrivateHeaderKitExecutableResolution
import PrivateHeaderKitHelperProtocol

public struct PrivateHeaderKitRawDumpCLI {
    package static func deviceSharedCacheInventory() throws -> PrivateHeaderKitSharedCacheInventory {
        try makeSharedCacheInventory()
    }

    package static func deviceCacheArchitecture() throws -> String {
        guard let cache = DyldCacheLoaded.current else {
            throw DyldSharedCacheAccessError.unavailable
        }
        return "cpu\(cache.cpu.typeRawValue)-sub\(cache.cpu.subtypeRawValue)"
    }

    public static func main() async {
        await main(arguments: Array(CommandLine.arguments.dropFirst()))
    }

    /// Runs a helper invocation. The leading `__raw-dump` command name is optional.
    public static func main(arguments: [String]) async {
        let args =
            arguments.first == PrivateHeaderKitHelperCommand.rawDump.rawValue
            ? Array(arguments.dropFirst()) : arguments
        if args == [PrivateHeaderKitHelperCommand.sharedCacheInventory.rawValue] {
            do {
                let data = try encodeSharedCacheInventory(makeSharedCacheInventory())
                guard let payload = String(data: data, encoding: .utf8) else {
                    throw CocoaError(.fileReadInapplicableStringEncoding)
                }
                print(payload)
            } catch {
                fputs("privateheaderkit __shared-cache-inventory: error: \(error)\n", stderr)
                exit(EXIT_FAILURE)
            }
            return
        }

        guard let parsed = parseArguments(args) else {
            printUsage()
            exit(EXIT_FAILURE)
        }

        do {
            try await runRawDumpAfterWritingProcessHandshake(parsed)
            try writeDiagnosticsReportIfRequested(parsed.options)
        } catch {
            do {
                try writeDiagnosticsReportIfRequested(parsed.options)
            } catch {
                fputs("privateheaderkit __raw-dump: diagnostics report error: \(error)\n", stderr)
            }
            fputs("privateheaderkit __raw-dump: error: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}

func runRawDumpAfterWritingProcessHandshake(
    _ parsed: ParsedArguments,
    writeProcessHandshake: (DumpOptions) throws -> Void = {
        try writeProcessHandshakeIfRequested($0)
    },
    runOperation: (ParsedArguments) async throws -> Void = run
) async throws {
    try writeProcessHandshake(parsed.options)
    try await runOperation(parsed)
}

func writeProcessHandshakeIfRequested(
    _ options: DumpOptions,
    processIdentifier: () -> Int32 = { getpid() },
    nowUnixMicroseconds: () throws -> Int64 = currentRealtimeUnixMicroseconds,
    executableName: () throws -> String = currentProcessExecutableName,
    executableMachOUUID: () throws -> UUID = currentProcessMachOUUID
) throws {
    guard let invocationID = options.processHandshakeID,
          let reportURL = options.processHandshakeReportURL
    else {
        return
    }
    let handshake = try PrivateHeaderKitRawDumpProcessHandshake(
        invocationID: invocationID,
        processIdentifier: processIdentifier(),
        helperStartedAtUnixMicroseconds: nowUnixMicroseconds(),
        executableName: executableName(),
        executableMachOUUID: executableMachOUUID()
    )
    try handshake.encoded().write(to: reportURL, options: .atomic)
}

func currentRealtimeUnixMicroseconds() throws -> Int64 {
    var time = timespec()
    guard clock_gettime(CLOCK_REALTIME, &time) == 0,
          let seconds = Int64(exactly: time.tv_sec),
          let nanoseconds = Int64(exactly: time.tv_nsec)
    else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    let (wholeMicroseconds, multiplyOverflow) = seconds.multipliedReportingOverflow(
        by: 1_000_000
    )
    let (result, addOverflow) = wholeMicroseconds.addingReportingOverflow(
        nanoseconds / 1_000
    )
    guard !multiplyOverflow, !addOverflow, result > 0 else {
        throw POSIXError(.EOVERFLOW)
    }
    return result
}

private func writeDiagnosticsReportIfRequested(_ options: DumpOptions) throws {
    guard let reportURL = options.diagnosticsReportURL else { return }
    try writeRawDumpDiagnosticsReport(options.objcDiagnostics.report, to: reportURL)
}
