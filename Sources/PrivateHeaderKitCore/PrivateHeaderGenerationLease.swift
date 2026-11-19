import Darwin
import Foundation

/// An advisory lock that keeps two processes from generating the same source at once.
package enum GenerationLease {
  package enum LeaseError: Error, Equatable, CustomStringConvertible, Sendable {
    case openFailed(path: String, errno: Int32)
    case acquisitionFailed(path: String, errno: Int32)
    case unavailable(path: String)

    package var description: String {
      switch self {
      case .openFailed(let path, let error):
        "failed to open generation lease at \(path): errno \(error)"
      case .acquisitionFailed(let path, let error):
        "failed to acquire generation lease at \(path): errno \(error)"
      case .unavailable(let path):
        "generation lease is already held at \(path)"
      }
    }
  }

  package static func withExclusiveLease<Result>(
    at lockURL: URL,
    operation: () async throws -> Result
  ) async throws -> Result {
    let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
    guard descriptor >= 0 else {
      throw LeaseError.openFailed(path: lockURL.path, errno: errno)
    }
    // Closing the descriptor releases the lock.
    defer { _ = close(descriptor) }

    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let error = errno
      if error == EWOULDBLOCK {
        throw LeaseError.unavailable(path: lockURL.path)
      }
      throw LeaseError.acquisitionFailed(path: lockURL.path, errno: error)
    }
    return try await operation()
  }
}
