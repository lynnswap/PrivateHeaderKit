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

private struct UntrackedSourceRecord: Codable, Sendable {
    let path: String
    let kind: String
    let sha256: String
}

private let sourceFingerprintChunkByteCount = 1024 * 1024
private let sourcePathSortChunkCount = 512
private let sourcePathMergeCheckInterval = 256
#if canImport(Darwin)
private let sourcePathMaximumByteCount = Int(PATH_MAX)
#else
private let sourcePathMaximumByteCount = 4096
#endif

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
    let releaseTags = try await sourceReleaseTags(
        repoRoot: repoRoot,
        runner: runner
    )
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
    let releaseTags = try await sourceReleaseTags(
        repoRoot: repoRoot,
        runner: runner
    )
    return try sourceVersion(
        environment: environment,
        commit: commit,
        releaseTags: releaseTags
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
    let canonicalHasher = SourceFingerprintCanonicalHasher()
    try await runner.runCaptureChunks(
        ["git", "diff", "--no-ext-diff", "--binary", "HEAD", "--"],
        env: nil,
        cwd: repoRoot,
        consumeStandardOutput: { chunk in
            try await canonicalHasher.consumeTrackedDiff(chunk)
        }
    )
    try await canonicalHasher.finishTrackedDiff()
    try await runner.runCaptureChunks(
        ["git", "ls-files", "--others", "--exclude-standard", "-z"],
        env: nil,
        cwd: repoRoot,
        consumeStandardOutput: { chunk in
            try await canonicalHasher.consumeUntrackedPathBytes(chunk)
        }
    )
    let untrackedPaths = try await canonicalHasher.finishUntrackedPaths()
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
        try await canonicalHasher.appendUntrackedRecord(UntrackedSourceRecord(
            path: path,
            kind: kind,
            sha256: sha256
        ))
    }
    return try await canonicalHasher.finalize()
}

private actor SourceReleaseTagCollector {
    private var pendingBytes = Data()
    private var releaseTags = CancellationAwareStringMergeSorter()

    func consume(_ chunk: Data) throws {
        try Task.checkCancellation()
        var chunkStart = chunk.startIndex
        while chunkStart < chunk.endIndex {
            try Task.checkCancellation()
            let chunkEnd = chunk.index(
                chunkStart,
                offsetBy: min(
                    sourceFingerprintChunkByteCount,
                    chunk.distance(from: chunkStart, to: chunk.endIndex)
                )
            )
            var segmentStart = chunkStart
            while let separator = chunk[segmentStart..<chunkEnd].firstIndex(
                of: UInt8(ascii: "\n")
            ) {
                try appendPendingBytes(chunk[segmentStart..<separator])
                try appendPendingTag()
                segmentStart = chunk.index(after: separator)
            }
            try appendPendingBytes(chunk[segmentStart..<chunkEnd])
            chunkStart = chunkEnd
        }
        try Task.checkCancellation()
    }

    func finish() throws -> [String] {
        try Task.checkCancellation()
        try appendPendingTag()
        return try releaseTags.finish()
    }

    private func appendPendingBytes(_ bytes: Data.SubSequence) throws {
        guard !bytes.isEmpty else { return }
        guard bytes.count <= sourcePathMaximumByteCount,
              pendingBytes.count <= sourcePathMaximumByteCount - bytes.count
        else {
            throw InstallError.message("Git reported an overlong release tag")
        }
        pendingBytes.append(contentsOf: bytes)
    }

    private func appendPendingTag() throws {
        try Task.checkCancellation()
        guard !pendingBytes.isEmpty else { return }
        let tag = String(decoding: pendingBytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        pendingBytes.removeAll(keepingCapacity: true)
        guard tag.range(
            of: #"^v[0-9]+[.][0-9]+[.][0-9]+([-.][0-9A-Za-z.-]+)?$"#,
            options: .regularExpression
        ) != nil else {
            return
        }
        try releaseTags.append(tag)
    }
}

private actor SourceFingerprintCanonicalHasher {
    private enum Phase: Equatable {
        case trackedDiff
        case untrackedPaths
        case untrackedRecords
        case finalized
    }

#if canImport(CryptoKit)
    private var hasher = SHA256()
#endif
    private var phase = Phase.trackedDiff
    private var pendingUntrackedPathBytes = Data()
    private var untrackedPaths = CancellationAwareStringMergeSorter()
    private var untrackedRecordCount = 0

    func consumeTrackedDiff(_ chunk: Data) throws {
        precondition(phase == .trackedDiff)
        try updateHash(with: chunk)
    }

    func finishTrackedDiff() throws {
        precondition(phase == .trackedDiff)
        try updateHash(with: Data([0]))
        phase = .untrackedPaths
    }

    func consumeUntrackedPathBytes(_ chunk: Data) throws {
        precondition(phase == .untrackedPaths)
        try Task.checkCancellation()
        var chunkStart = chunk.startIndex
        while chunkStart < chunk.endIndex {
            try Task.checkCancellation()
            let chunkEnd = chunk.index(
                chunkStart,
                offsetBy: min(
                    sourceFingerprintChunkByteCount,
                    chunk.distance(from: chunkStart, to: chunk.endIndex)
                )
            )
            var segmentStart = chunkStart
            while let separator = chunk[segmentStart..<chunkEnd].firstIndex(of: 0) {
                try appendPendingPathBytes(chunk[segmentStart..<separator])
                try appendPendingPath()
                segmentStart = chunk.index(after: separator)
            }
            try appendPendingPathBytes(chunk[segmentStart..<chunkEnd])
            chunkStart = chunkEnd
        }
        try Task.checkCancellation()
    }

    func finishUntrackedPaths() throws -> [String] {
        precondition(phase == .untrackedPaths)
        try Task.checkCancellation()
        try appendPendingPath()
        let result = try untrackedPaths.finish()
        try updateHash(with: Data("[".utf8))
        phase = .untrackedRecords
        return result
    }

    func appendUntrackedRecord(_ record: UntrackedSourceRecord) throws {
        precondition(phase == .untrackedRecords)
        try Task.checkCancellation()
        if untrackedRecordCount > 0 {
            try updateHash(with: Data([UInt8(ascii: ",")]))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try updateHash(with: encoder.encode(record))
        untrackedRecordCount += 1
    }

    func finalize() throws -> String {
        precondition(phase == .untrackedRecords)
        try updateHash(with: Data("]".utf8))
        try Task.checkCancellation()
        phase = .finalized
#if canImport(CryptoKit)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
#else
        throw InstallError.message(
            "source input fingerprinting is unavailable on this platform"
        )
#endif
    }

    private func appendPendingPathBytes(_ bytes: Data.SubSequence) throws {
        guard !bytes.isEmpty else { return }
        guard bytes.count <= sourcePathMaximumByteCount,
              pendingUntrackedPathBytes.count
                <= sourcePathMaximumByteCount - bytes.count
        else {
            throw InstallError.message(
                "Git reported an overlong untracked source path"
            )
        }
        pendingUntrackedPathBytes.append(contentsOf: bytes)
    }

    private func appendPendingPath() throws {
        try Task.checkCancellation()
        guard !pendingUntrackedPathBytes.isEmpty else { return }
        try untrackedPaths.append(
            String(decoding: pendingUntrackedPathBytes, as: UTF8.self)
        )
        pendingUntrackedPathBytes.removeAll(keepingCapacity: true)
    }

    private func updateHash(with data: Data) throws {
#if canImport(CryptoKit)
        try Task.checkCancellation()
        var chunkStart = data.startIndex
        while chunkStart < data.endIndex {
            try Task.checkCancellation()
            let chunkEnd = data.index(
                chunkStart,
                offsetBy: min(
                    sourceFingerprintChunkByteCount,
                    data.distance(from: chunkStart, to: data.endIndex)
                )
            )
            hasher.update(data: data[chunkStart..<chunkEnd])
            chunkStart = chunkEnd
        }
        try Task.checkCancellation()
#else
        throw InstallError.message(
            "source input fingerprinting is unavailable on this platform"
        )
#endif
    }
}

private struct CancellationAwareStringMergeSorter {
    private var buffer: [String] = []
    private var runs: [[String]?] = Array(
        repeating: nil,
        count: Int.bitWidth
    )

    init() {
        buffer.reserveCapacity(sourcePathSortChunkCount)
    }

    mutating func append(
        _ value: String,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws {
        try checkCancellation()
        buffer.append(value)
        if buffer.count == sourcePathSortChunkCount {
            try flushBuffer(checkCancellation: checkCancellation)
        }
    }

    mutating func finish(
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> [String] {
        try flushBuffer(checkCancellation: checkCancellation)
        var result: [String] = []
        for run in runs {
            try checkCancellation()
            guard let run else { continue }
            if result.isEmpty {
                result = run
            } else {
                result = try mergeSortedSourcePaths(
                    run,
                    result,
                    checkCancellation: checkCancellation
                )
            }
        }
        try checkCancellation()
        runs = Array(repeating: nil, count: Int.bitWidth)
        return result
    }

    private mutating func flushBuffer(
        checkCancellation: () throws -> Void
    ) throws {
        guard !buffer.isEmpty else { return }
        var carry = try cancellationAwareSortedBuffer(
            buffer,
            checkCancellation: checkCancellation
        )
        buffer.removeAll(keepingCapacity: true)
        var level = 0
        while true {
            try checkCancellation()
            guard level < runs.count else {
                preconditionFailure("source string count exceeds Int capacity")
            }
            guard let run = runs[level] else {
                runs[level] = carry
                return
            }
            runs[level] = nil
            carry = try mergeSortedSourcePaths(
                run,
                carry,
                checkCancellation: checkCancellation
            )
            level += 1
        }
    }
}

func cancellationAwareSortedStrings(
    _ values: [String],
    checkCancellation: () throws -> Void = { try Task.checkCancellation() }
) throws -> [String] {
    var sorter = CancellationAwareStringMergeSorter()
    for value in values {
        try sorter.append(value, checkCancellation: checkCancellation)
    }
    return try sorter.finish(checkCancellation: checkCancellation)
}

private func cancellationAwareSortedBuffer(
    _ values: [String],
    checkCancellation: () throws -> Void
) throws -> [String] {
    var runs: [[String]] = []
    runs.reserveCapacity(values.count)
    for value in values {
        try checkCancellation()
        runs.append([value])
    }
    guard !runs.isEmpty else { return [] }
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

private func sourceReleaseTags(
    repoRoot: URL,
    runner: CommandRunning
) async throws -> [String] {
    let collector = SourceReleaseTagCollector()
    try await runner.runCaptureChunks(
        ["git", "tag", "--points-at", "HEAD"],
        env: nil,
        cwd: repoRoot,
        consumeStandardOutput: { chunk in
            try await collector.consume(chunk)
        }
    )
    return try await collector.finish()
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
