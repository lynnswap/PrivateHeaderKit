import Foundation
import PrivateHeaderKitTooling

#if canImport(CryptoKit)
import CryptoKit
#endif

#if canImport(Darwin)
import Darwin
#endif

struct SourceSnapshot: Equatable, Sendable {
    let head: String
    let effectiveCommit: String
    let dirtyInputFingerprint: String
    let releaseTags: [String]
    let effectiveVersion: String
}

private struct UntrackedSourceRecord: Codable {
    let path: String
    let kind: String
    let sha256: String
}

private let sourceFingerprintChunkByteCount = 1024 * 1024
private let sourcePathSortChunkCount = 512
private let sourcePathMergeCheckInterval = 256

func captureSourceSnapshot(
    repoRoot: URL,
    environment: [String: String],
    runner: CommandRunning,
    fileManager: FileManager
) async throws -> SourceSnapshot {
    try Task.checkCancellation()
    let head = try await gitHead(repoRoot: repoRoot, runner: runner).lowercased()
    let effectiveCommit = try effectiveSourceCommit(
        environment: environment,
        head: head
    ).lowercased()
    let tagOutput = try await runner.runCapture(
        ["git", "tag", "--points-at", "HEAD"],
        env: nil,
        cwd: repoRoot
    )
    try Task.checkCancellation()
    let releaseTags = sourceReleaseTags(from: tagOutput)
    let effectiveVersion = try sourceVersion(
        environment: environment,
        commit: effectiveCommit,
        releaseTags: releaseTags
    )
    let dirtyInputFingerprint = try await sourceDirtyInputFingerprint(
        repoRoot: repoRoot,
        runner: runner,
        fileManager: fileManager
    )
    return SourceSnapshot(
        head: head,
        effectiveCommit: effectiveCommit,
        dirtyInputFingerprint: dirtyInputFingerprint,
        releaseTags: releaseTags,
        effectiveVersion: effectiveVersion
    )
}

func sourceCommit(
    repoRoot: URL,
    environment: [String: String],
    runner: CommandRunning
) async throws -> String {
    try effectiveSourceCommit(
        environment: environment,
        head: try await gitHead(repoRoot: repoRoot, runner: runner)
    )
}

func sourceVersion(
    repoRoot: URL,
    environment: [String: String],
    runner: CommandRunning,
    commit: String
) async throws -> String {
    let output = try await runner.runCapture(
        ["git", "tag", "--points-at", "HEAD"],
        env: nil,
        cwd: repoRoot
    )
    try Task.checkCancellation()
    return try sourceVersion(
        environment: environment,
        commit: commit,
        releaseTags: sourceReleaseTags(from: output)
    )
}

private func gitHead(
    repoRoot: URL,
    runner: CommandRunning
) async throws -> String {
    let output = try await runner.runCapture(
        ["git", "rev-parse", "HEAD"],
        env: nil,
        cwd: repoRoot
    )
    try Task.checkCancellation()
    guard let value = output
        .split(whereSeparator: \Character.isWhitespace)
        .map(String.init)
        .first,
        value.range(of: #"^[0-9A-Fa-f]{40}$"#, options: .regularExpression) != nil
    else {
        throw InstallError.message("failed to determine source HEAD")
    }
    return value
}

private func effectiveSourceCommit(
    environment: [String: String],
    head: String
) throws -> String {
    let value = nonEmptySourceValue(
        environment["PRIVATEHEADERKIT_BUILD_COMMIT"]
    ) ?? head
    guard value.range(
        of: #"^[0-9A-Fa-f]{40}$"#,
        options: .regularExpression
    ) != nil else {
        throw InstallError.message(
            "source commit provenance must be a full 40-character Git SHA"
        )
    }
    return value
}

private func sourceDirtyInputFingerprint(
    repoRoot: URL,
    runner: CommandRunning,
    fileManager: FileManager
) async throws -> String {
    let trackedDiff = try await runner.runCapture(
        ["git", "diff", "--no-ext-diff", "--binary", "HEAD", "--"],
        env: nil,
        cwd: repoRoot
    )
    try Task.checkCancellation()
    let untrackedOutput = try await runner.runCapture(
        ["git", "ls-files", "--others", "--exclude-standard", "-z"],
        env: nil,
        cwd: repoRoot
    )
    try Task.checkCancellation()
    let untrackedPaths = try cancellationAwareSortedSourcePaths(
        untrackedOutput
        .split(separator: "\0", omittingEmptySubsequences: true)
        .map(String.init)
    )
    var records: [UntrackedSourceRecord] = []
    records.reserveCapacity(untrackedPaths.count)
    for path in untrackedPaths {
        try Task.checkCancellation()
        guard !path.hasPrefix("/"),
              !path.split(separator: "/").contains("..")
        else {
            throw InstallError.message(
                "Git reported an unsafe untracked source path: \(path)"
            )
        }
        let url = repoRoot.appendingPathComponent(path, isDirectory: false)
#if canImport(Darwin)
        var metadata = stat()
        let result = url.path.withCString { Darwin.lstat($0, &metadata) }
        guard result == 0 else {
            throw InstallError.message(
                "failed to inspect untracked source input at \(url.path): errno \(errno)"
            )
        }
        let kind: String
        let sha256: String
        switch metadata.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFREG):
            kind = "regular"
            sha256 = try sourceSHA256Hex(ofFileAt: url)
        case mode_t(S_IFLNK):
            kind = "symlink"
            sha256 = try sourceSHA256Hex(
                Data(try fileManager.destinationOfSymbolicLink(atPath: url.path).utf8)
            )
        default:
            throw InstallError.message(
                "untracked source input is not a regular file or symbolic link: \(url.path)"
            )
        }
#else
        throw InstallError.message(
            "source input fingerprinting is unavailable on this platform"
        )
#endif
        records.append(UntrackedSourceRecord(
            path: path,
            kind: kind,
            sha256: sha256
        ))
    }

    try Task.checkCancellation()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let untrackedData = try encoder.encode(records)
    var canonical = Data(trackedDiff.utf8)
    canonical.append(0)
    canonical.append(untrackedData)
    return try sourceSHA256Hex(canonical)
}

func cancellationAwareSortedSourcePaths(
    _ paths: [String],
    checkCancellation: () throws -> Void = { try Task.checkCancellation() }
) throws -> [String] {
    guard paths.count > 1 else {
        try checkCancellation()
        return paths
    }

    var runs: [[String]] = []
    runs.reserveCapacity(
        (paths.count + sourcePathSortChunkCount - 1) / sourcePathSortChunkCount
    )
    for start in stride(from: 0, to: paths.count, by: sourcePathSortChunkCount) {
        try checkCancellation()
        let end = min(start + sourcePathSortChunkCount, paths.count)
        runs.append(paths[start..<end].sorted(by: sourcePathPrecedes))
    }

    while runs.count > 1 {
        var mergedRuns: [[String]] = []
        mergedRuns.reserveCapacity((runs.count + 1) / 2)
        var index = 0
        while index < runs.count {
            try checkCancellation()
            guard index + 1 < runs.count else {
                mergedRuns.append(runs[index])
                break
            }
            mergedRuns.append(try mergeSortedSourcePaths(
                runs[index],
                runs[index + 1],
                checkCancellation: checkCancellation
            ))
            index += 2
        }
        runs = mergedRuns
    }
    try checkCancellation()
    return runs[0]
}

private func mergeSortedSourcePaths(
    _ left: [String],
    _ right: [String],
    checkCancellation: () throws -> Void
) throws -> [String] {
    var merged: [String] = []
    merged.reserveCapacity(left.count + right.count)
    var leftIndex = 0
    var rightIndex = 0
    var comparisonCount = 0
    while leftIndex < left.count, rightIndex < right.count {
        if comparisonCount.isMultiple(of: sourcePathMergeCheckInterval) {
            try checkCancellation()
        }
        comparisonCount += 1
        if sourcePathPrecedes(left[leftIndex], right[rightIndex]) {
            merged.append(left[leftIndex])
            leftIndex += 1
        } else {
            merged.append(right[rightIndex])
            rightIndex += 1
        }
    }
    while leftIndex < left.count {
        try checkCancellation()
        let end = min(leftIndex + sourcePathMergeCheckInterval, left.count)
        merged.append(contentsOf: left[leftIndex..<end])
        leftIndex = end
    }
    while rightIndex < right.count {
        try checkCancellation()
        let end = min(rightIndex + sourcePathMergeCheckInterval, right.count)
        merged.append(contentsOf: right[rightIndex..<end])
        rightIndex = end
    }
    try checkCancellation()
    return merged
}

private func sourcePathPrecedes(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
}

private func sourceReleaseTags(from output: String) -> [String] {
    output
        .split(whereSeparator: \Character.isNewline)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter {
            $0.range(
                of: #"^v[0-9]+[.][0-9]+[.][0-9]+([-.][0-9A-Za-z.-]+)?$"#,
                options: .regularExpression
            ) != nil
        }
        .sorted()
}

private func sourceVersion(
    environment: [String: String],
    commit: String,
    releaseTags: [String]
) throws -> String {
    if let value = nonEmptySourceValue(
        environment["PRIVATEHEADERKIT_BUILD_VERSION"]
    ) {
        return value
    }
    switch releaseTags.count {
    case 0:
        return "0.0.0-dev.\(commit.lowercased().prefix(12))"
    case 1:
        return releaseTags[0]
    default:
        throw InstallError.message(
            "multiple release tags point at HEAD: \(releaseTags.joined(separator: ", "))"
        )
    }
}

private func sourceSHA256Hex(_ data: Data) throws -> String {
#if canImport(CryptoKit)
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
#else
    throw InstallError.message(
        "source input fingerprinting is unavailable on this platform"
    )
#endif
}

func sourceSHA256Hex(
    ofFileAt url: URL,
    checkCancellation: () throws -> Void = { try Task.checkCancellation() }
) throws -> String {
#if canImport(CryptoKit)
    try checkCancellation()
    let handle: FileHandle
    do {
        handle = try FileHandle(forReadingFrom: url)
    } catch {
        throw InstallError.message(
            "failed to open untracked source input at \(url.path): \(error)"
        )
    }
    defer { try? handle.close() }

    var hasher = SHA256()
    while true {
        try checkCancellation()
        let chunk: Data
        do {
            chunk = try handle.read(upToCount: sourceFingerprintChunkByteCount) ?? Data()
        } catch {
            throw InstallError.message(
                "failed to read untracked source input at \(url.path): \(error)"
            )
        }
        if chunk.isEmpty {
            break
        }
        hasher.update(data: chunk)
    }
    try checkCancellation()
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
#else
    throw InstallError.message(
        "source input fingerprinting is unavailable on this platform"
    )
#endif
}

private func nonEmptySourceValue(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty
    else {
        return nil
    }
    return value
}
