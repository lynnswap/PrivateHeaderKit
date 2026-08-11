import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

package enum ManagedFileSystem {
  package enum ItemKind: String, Equatable, Sendable {
    case directory
    case regular
    case symbolicLink
    case other
  }

  package enum Failure: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidPath(String)
    case unexpectedKind(path: String, expected: String, actual: ItemKind)
    case posix(operation: String, path: String, errno: Int32)

    package var description: String {
      switch self {
      case .invalidPath(let path):
        "invalid managed filesystem path: \(path)"
      case .unexpectedKind(let path, let expected, let actual):
        "managed filesystem item at \(path) is \(actual.rawValue), expected \(expected)"
      case .posix(let operation, let path, let code):
        "\(operation) failed for \(path): errno \(code)"
      }
    }
  }

  package static func itemKind(at url: URL) throws -> ItemKind? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      let code = errno
      if code == ENOENT { return nil }
      throw Failure.posix(operation: "lstat", path: url.path, errno: code)
    }
    let kind = info.st_mode & mode_t(S_IFMT)
    if kind == mode_t(S_IFDIR) { return .directory }
    if kind == mode_t(S_IFREG) { return .regular }
    if kind == mode_t(S_IFLNK) { return .symbolicLink }
    return .other
  }

  package static func ensureRealDirectory(_ url: URL) throws {
    if let kind = try itemKind(at: url) {
      guard kind == .directory else {
        throw Failure.unexpectedKind(path: url.path, expected: "directory", actual: kind)
      }
      return
    }
    let parent = url.deletingLastPathComponent()
    guard parent.path != url.path else {
      throw Failure.invalidPath(url.path)
    }
    try ensureRealDirectory(parent)
    guard mkdir(url.path, mode_t(0o755)) == 0 else {
      let code = errno
      if code == EEXIST, try itemKind(at: url) == .directory { return }
      throw Failure.posix(operation: "mkdir", path: url.path, errno: code)
    }
  }

  package static func atomicRename(from source: URL, to destination: URL) throws {
    guard rename(source.path, destination.path) == 0 else {
      throw Failure.posix(
        operation: "rename",
        path: "\(source.path) -> \(destination.path)",
        errno: errno
      )
    }
  }

  @discardableResult
  package static func requireRegularFileOrMissing(_ url: URL) throws -> Bool {
    guard let kind = try itemKind(at: url) else { return false }
    guard kind == .regular else {
      throw Failure.unexpectedKind(
        path: url.path, expected: "regular file or missing", actual: kind)
    }
    return true
  }

  package static func canonicalizedDirectoryResolvingExistingAncestor(_ url: URL) throws -> URL {
    guard url.isFileURL else { throw Failure.invalidPath(url.absoluteString) }
    var cursor = url.standardizedFileURL
    var missingComponents: [String] = []
    while true {
      if let kind = try itemKind(at: cursor) {
        guard kind == .directory || kind == .symbolicLink else {
          throw Failure.unexpectedKind(
            path: cursor.path,
            expected: "directory or directory symlink ancestor",
            actual: kind
          )
        }
        let resolved = cursor.resolvingSymlinksInPath().standardizedFileURL
        guard try itemKind(at: resolved) == .directory else {
          throw Failure.invalidPath(cursor.path)
        }
        return missingComponents.reversed().reduce(into: resolved) { result, component in
          result.appendPathComponent(component, isDirectory: true)
        }
      }
      guard cursor.path != "/" else { throw Failure.invalidPath(url.path) }
      missingComponents.append(cursor.lastPathComponent)
      cursor.deleteLastPathComponent()
    }
  }
}
