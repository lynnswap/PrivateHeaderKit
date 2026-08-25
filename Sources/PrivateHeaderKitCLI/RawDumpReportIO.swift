import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum RawDumpReportIO {
    enum Failure: Error, Equatable, CustomStringConvertible, Sendable {
        case missing
        case openFailed(errno: Int32)
        case inspectionFailed(errno: Int32)
        case notRegularFile
        case invalidFileSize
        case tooLarge(actual: Int)
        case readFailed(errno: Int32)

        var description: String {
            switch self {
            case .missing:
                "report is missing"
            case .openFailed(let errorCode):
                "could not open report: errno \(errorCode)"
            case .inspectionFailed(let errorCode):
                "could not inspect report: errno \(errorCode)"
            case .notRegularFile:
                "report is not a regular file"
            case .invalidFileSize:
                "report size is invalid"
            case .tooLarge(let actual):
                "report exceeds its maximum size after \(actual) bytes"
            case .readFailed(let errorCode):
                "could not read report: errno \(errorCode)"
            }
        }
    }

    final class OpenedFile {
        private let descriptor: Int32

        init(at url: URL) throws {
            let openedDescriptor = url.path.withCString { path in
                systemOpen(
                    path,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY
                )
            }
            guard openedDescriptor >= 0 else {
                let errorCode = errno
                if errorCode == ENOENT {
                    throw Failure.missing
                }
                throw Failure.openFailed(errno: errorCode)
            }
            descriptor = openedDescriptor
        }

        deinit {
            _ = systemClose(descriptor)
        }

        func read(maximumByteCount: Int) throws -> Data {
            precondition(
                maximumByteCount >= 0 && maximumByteCount < Int.max,
                "RawDumpReportIO owns a finite nonnegative maximum byte count"
            )

            var metadata = stat()
            guard systemFstat(descriptor, &metadata) == 0 else {
                throw Failure.inspectionFailed(errno: errno)
            }
            guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw Failure.notRegularFile
            }
            guard metadata.st_size >= 0,
                  let declaredByteCount = Int(exactly: metadata.st_size)
            else {
                throw Failure.invalidFileSize
            }
            guard declaredByteCount <= maximumByteCount else {
                throw Failure.tooLarge(actual: declaredByteCount)
            }

            let overflowByteCount = maximumByteCount + 1
            var contents = Data()
            contents.reserveCapacity(declaredByteCount)
            var buffer = [UInt8](
                repeating: 0,
                count: min(64 * 1_024, overflowByteCount)
            )

            while contents.count < overflowByteCount {
                let requestedByteCount = min(
                    buffer.count,
                    overflowByteCount - contents.count
                )
                let readByteCount = buffer.withUnsafeMutableBytes { bytes in
                    systemRead(descriptor, bytes.baseAddress, requestedByteCount)
                }
                if readByteCount > 0 {
                    contents.append(contentsOf: buffer.prefix(readByteCount))
                    continue
                }
                if readByteCount == 0 {
                    break
                }
                let errorCode = errno
                if errorCode == EINTR {
                    continue
                }
                throw Failure.readFailed(errno: errorCode)
            }

            guard contents.count <= maximumByteCount else {
                throw Failure.tooLarge(actual: contents.count)
            }
            return contents
        }
    }

    static func read(
        at url: URL,
        maximumByteCount: Int
    ) throws -> Data {
        try OpenedFile(at: url).read(maximumByteCount: maximumByteCount)
    }
}

private func systemOpen(
    _ path: UnsafePointer<CChar>,
    _ flags: Int32
) -> Int32 {
#if canImport(Darwin)
    Darwin.open(path, flags)
#elseif canImport(Glibc)
    Glibc.open(path, flags)
#endif
}

private func systemFstat(
    _ descriptor: Int32,
    _ metadata: UnsafeMutablePointer<stat>
) -> Int32 {
#if canImport(Darwin)
    Darwin.fstat(descriptor, metadata)
#elseif canImport(Glibc)
    Glibc.fstat(descriptor, metadata)
#endif
}

private func systemRead(
    _ descriptor: Int32,
    _ buffer: UnsafeMutableRawPointer?,
    _ byteCount: Int
) -> Int {
#if canImport(Darwin)
    Darwin.read(descriptor, buffer, byteCount)
#elseif canImport(Glibc)
    Glibc.read(descriptor, buffer, byteCount)
#endif
}

private func systemClose(_ descriptor: Int32) -> Int32 {
#if canImport(Darwin)
    Darwin.close(descriptor)
#elseif canImport(Glibc)
    Glibc.close(descriptor)
#endif
}
