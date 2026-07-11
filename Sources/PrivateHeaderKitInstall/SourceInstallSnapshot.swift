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
    let untrackedPaths = untrackedOutput
        .split(separator: "\0", omittingEmptySubsequences: true)
        .map(String.init)
        .sorted()
    let records = try untrackedPaths.map { path -> UntrackedSourceRecord in
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
        let contents: Data
        switch metadata.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFREG):
            kind = "regular"
            contents = try Data(contentsOf: url)
        case mode_t(S_IFLNK):
            kind = "symlink"
            contents = Data(
                try fileManager.destinationOfSymbolicLink(atPath: url.path).utf8
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
        return UntrackedSourceRecord(
            path: path,
            kind: kind,
            sha256: try sourceSHA256Hex(contents)
        )
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let untrackedData = try encoder.encode(records)
    var canonical = Data(trackedDiff.utf8)
    canonical.append(0)
    canonical.append(untrackedData)
    return try sourceSHA256Hex(canonical)
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

private func nonEmptySourceValue(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty
    else {
        return nil
    }
    return value
}
