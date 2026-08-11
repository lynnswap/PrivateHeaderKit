import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

private let fileSHA256ChunkByteCount = 1024 * 1024

enum FileSHA256Context {
    case artifactValidation
    case untrackedSourceInput

    var unavailableMessage: String {
        switch self {
        case .artifactValidation:
            "SHA-256 validation is unavailable on this platform"
        case .untrackedSourceInput:
            "source input fingerprinting is unavailable on this platform"
        }
    }

    func openFailureMessage(url: URL, error: any Error) -> String {
        switch self {
        case .artifactValidation:
            "failed to open artifact for SHA-256 validation at \(url.path): \(error)"
        case .untrackedSourceInput:
            "failed to open untracked source input at \(url.path): \(error)"
        }
    }

    func readFailureMessage(url: URL, error: any Error) -> String {
        switch self {
        case .artifactValidation:
            "failed to read artifact for SHA-256 validation at \(url.path): \(error)"
        case .untrackedSourceInput:
            "failed to read untracked source input at \(url.path): \(error)"
        }
    }
}

func fileSHA256Hex(
    ofFileAt url: URL,
    context: FileSHA256Context,
    checkCancellation: () throws -> Void
) throws -> String {
#if canImport(CryptoKit)
    try checkCancellation()
    let handle: FileHandle
    do {
        handle = try FileHandle(forReadingFrom: url)
    } catch {
        throw InstallError.message(context.openFailureMessage(url: url, error: error))
    }
    defer { try? handle.close() }

    var hasher = SHA256()
    while true {
        try checkCancellation()
        let chunk: Data
        do {
            chunk = try handle.read(upToCount: fileSHA256ChunkByteCount) ?? Data()
        } catch {
            throw InstallError.message(context.readFailureMessage(url: url, error: error))
        }
        if chunk.isEmpty {
            break
        }
        hasher.update(data: chunk)
    }
    try checkCancellation()
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
#else
    throw InstallError.message(context.unavailableMessage)
#endif
}
