import Darwin
import Foundation

extension PrivateHeaderGeneration {
  /// Replaces one target's published files in a source's header directory.
  struct TargetPublisher {
    let artifactDirectory: URL

    /// Removes the files a target published before, then moves its staged files into place.
    ///
    /// Removing first keeps a header whose name changed only in letter case from being
    /// deleted as its own predecessor on a case-insensitive volume. A process that stops
    /// partway leaves the target incomplete until it is generated again.
    func replace(
      _ staleArtifacts: Set<ArtifactPath>,
      with stagedFiles: [ArtifactPath: URL]
    ) throws {
      let fileManager = FileManager.default
      for artifact in staleArtifacts {
        try removeItemIfPresent(at: url(for: artifact))
      }
      for (artifact, stagedFile) in stagedFiles {
        let destination = url(for: artifact)
        try fileManager.createDirectory(
          at: destination.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        do {
          try fileManager.moveItem(at: stagedFile, to: destination)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
          // Output that no state database describes, such as headers kept after `.state`
          // was deleted, is replaced like the target's own files.
          try fileManager.removeItem(at: destination)
          try fileManager.moveItem(at: stagedFile, to: destination)
        }
      }
      removeEmptyDirectories(leftBy: staleArtifacts)
    }

    private func url(for artifact: ArtifactPath) -> URL {
      artifactDirectory.appending(path: artifact.rawValue, directoryHint: .notDirectory)
    }

    private func removeItemIfPresent(at url: URL) throws {
      do {
        try FileManager.default.removeItem(at: url)
      } catch let error as CocoaError where error.code == .fileNoSuchFile {
      }
    }

    /// Removes directories that held only stale files. A directory that cannot be removed
    /// stays behind empty, which changes nothing a consumer reads.
    private func removeEmptyDirectories(leftBy staleArtifacts: Set<ArtifactPath>) {
      let parents = Set(
        staleArtifacts.map { $0.rawValue.split(separator: "/").dropLast().map(String.init) }
      )
      for parent in parents {
        var components = parent
        while !components.isEmpty {
          let directory = artifactDirectory.appending(
            path: components.joined(separator: "/"),
            directoryHint: .isDirectory
          )
          guard rmdir(directory.path) == 0 || errno == ENOENT else { break }
          components.removeLast()
        }
      }
    }
  }
}
