import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

package enum GenerationLease {
  package enum LeaseError: Error, Equatable, CustomStringConvertible, Sendable {
    case openFailed(path: String, errno: Int32)
    case acquisitionFailed(path: String, errno: Int32)
    case unavailable(path: String)
    case invalidFileType(path: String)

    package var description: String {
      switch self {
      case .openFailed(let path, let error):
        "failed to open generation lease at \(path): errno \(error)"
      case .acquisitionFailed(let path, let error):
        "failed to acquire generation lease at \(path): errno \(error)"
      case .unavailable(let path):
        "generation lease is already held at \(path)"
      case .invalidFileType(let path):
        "generation lease is not a regular file: \(path)"
      }
    }
  }

  package static func withExclusiveLease<Result>(
    at lockURL: URL,
    operation: () async throws -> Result
  ) async throws -> Result {
    try Task.checkCancellation()
    do {
      guard
        try ManagedFileSystem.itemKind(
          at: lockURL.deletingLastPathComponent()
        ) == .directory
      else {
        throw LeaseError.openFailed(path: lockURL.path, errno: EINVAL)
      }
    } catch let error as ManagedFileSystem.Failure {
      switch error {
      case .posix(_, _, let code):
        throw LeaseError.openFailed(path: lockURL.path, errno: code)
      case .invalidPath, .unexpectedKind:
        throw LeaseError.openFailed(path: lockURL.path, errno: EINVAL)
      }
    }
    let descriptor = open(
      lockURL.path,
      O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
      mode_t(0o600)
    )
    guard descriptor >= 0 else {
      throw LeaseError.openFailed(path: lockURL.path, errno: errno)
    }
    defer { _ = close(descriptor) }
    var descriptorInfo = stat()
    guard fstat(descriptor, &descriptorInfo) == 0 else {
      throw LeaseError.openFailed(path: lockURL.path, errno: errno)
    }
    guard descriptorInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
      throw LeaseError.invalidFileType(path: lockURL.path)
    }

    try Task.checkCancellation()
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let error = errno
      if error == EWOULDBLOCK || error == EAGAIN {
        throw LeaseError.unavailable(path: lockURL.path)
      }
      throw LeaseError.acquisitionFailed(path: lockURL.path, errno: error)
    }
    defer { _ = flock(descriptor, LOCK_UN) }

    return try await operation()
  }
}
