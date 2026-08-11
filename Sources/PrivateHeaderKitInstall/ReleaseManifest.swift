import Foundation
import PrivateHeaderKitTooling

#if canImport(CryptoKit)
import CryptoKit
#endif

enum InstallArtifactName: String, Codable, CaseIterable, Comparable, Sendable {
    case publicCommand = "privateheaderkit"
    case rawDumpHelper = "privateheaderkit-raw-helper"
    case simulatorHelper = "privateheaderkit-sim-helper"

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var expectedPlatform: InstallArtifactPlatform {
        switch self {
        case .publicCommand, .rawDumpHelper:
            .macOS
        case .simulatorHelper:
            .iOSSimulator
        }
    }
}

enum InstallArtifactPlatform: String, Codable, Sendable {
    case macOS
    case iOSSimulator
}

enum InstallCodeSignaturePolicy: String, Codable, Sendable {
    case valid
}

struct ReleaseArtifactRecord: Codable, Equatable, Sendable {
    let name: InstallArtifactName
    let sha256: String
    let architectures: [String]
    let platform: InstallArtifactPlatform
    let codeSignaturePolicy: InstallCodeSignaturePolicy
}

struct ReleaseManifest: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let fileName = "release.json"

    let schemaVersion: Int
    let version: String
    let commit: String
    let cohort: String
    let artifacts: [ReleaseArtifactRecord]

    init(
        version: String,
        commit: String,
        artifacts: [ReleaseArtifactRecord]
    ) throws {
        let sortedArtifacts = artifacts.sorted { $0.name < $1.name }
        self.schemaVersion = Self.schemaVersion
        self.version = version
        self.commit = commit.lowercased()
        self.cohort = try Self.cohortIdentifier(
            version: version,
            artifacts: sortedArtifacts
        )
        self.artifacts = sortedArtifacts
        try validate()
    }

    func validate() throws {
        guard schemaVersion == Self.schemaVersion else {
            throw InstallError.message(
                "unsupported release manifest schema: \(schemaVersion)"
            )
        }
        guard commit.range(
            of: #"^[0-9a-f]{40}$"#,
            options: .regularExpression
        ) != nil else {
            throw InstallError.message(
                "release commit must be a full lowercase 40-character Git SHA: \(commit)"
            )
        }
        let expectedCohort = try Self.cohortIdentifier(
            version: version,
            artifacts: artifacts
        )
        guard cohort == expectedCohort else {
            throw InstallError.message(
                "release manifest cohort mismatch: expected \(expectedCohort), got \(cohort)"
            )
        }

        let expectedNames = Set(InstallArtifactName.allCases)
        let actualNames = Set(artifacts.map(\.name))
        guard artifacts.count == expectedNames.count, actualNames == expectedNames else {
            throw InstallError.message(
                "release manifest must describe exactly: \(expectedNames.map(\.rawValue).sorted().joined(separator: ", "))"
            )
        }
        guard artifacts.map(\.name) == artifacts.map(\.name).sorted() else {
            throw InstallError.message(
                "release manifest artifacts must use canonical name order"
            )
        }

        for artifact in artifacts {
            guard artifact.sha256.range(
                of: #"^[0-9a-f]{64}$"#,
                options: .regularExpression
            ) != nil else {
                throw InstallError.message(
                    "invalid SHA-256 for \(artifact.name.rawValue): \(artifact.sha256)"
                )
            }
            guard !artifact.architectures.isEmpty,
                  artifact.architectures.allSatisfy(Self.isSafeIdentifierComponent),
                  artifact.architectures == artifact.architectures.sorted(),
                  Set(artifact.architectures).count == artifact.architectures.count
            else {
                throw InstallError.message(
                    "invalid architecture list for \(artifact.name.rawValue)"
                )
            }
            guard artifact.platform == artifact.name.expectedPlatform else {
                throw InstallError.message(
                    "platform mismatch for \(artifact.name.rawValue): expected \(artifact.name.expectedPlatform.rawValue), got \(artifact.platform.rawValue)"
                )
            }
            guard artifact.codeSignaturePolicy == .valid else {
                throw InstallError.message(
                    "unsupported code signature policy for \(artifact.name.rawValue)"
                )
            }
        }
    }

    func artifact(named name: InstallArtifactName) throws -> ReleaseArtifactRecord {
        guard let artifact = artifacts.first(where: { $0.name == name }) else {
            throw InstallError.message(
                "release manifest is missing \(name.rawValue)"
            )
        }
        return artifact
    }

    static func cohortIdentifier(
        version: String,
        artifacts: [ReleaseArtifactRecord]
    ) throws -> String {
        guard isSafeIdentifierComponent(version), !version.isEmpty else {
            throw InstallError.message("release version is not safe: \(version)")
        }
#if canImport(CryptoKit)
        let canonicalRecords = artifacts
            .sorted { $0.name < $1.name }
            .map { artifact in
                [
                    artifact.name.rawValue,
                    artifact.sha256,
                    artifact.platform.rawValue,
                    artifact.architectures.sorted().joined(separator: ","),
                ].joined(separator: "|")
            }
            .joined(separator: "\n") + "\n"
        let digest = SHA256.hash(data: Data(canonicalRecords.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(version)+\(digest)"
#else
        throw InstallError.message("cohort SHA-256 calculation is unavailable on this platform")
#endif
    }

    static func read(from url: URL) throws -> ReleaseManifest {
        let manifest = try JSONDecoder().decode(
            ReleaseManifest.self,
            from: Data(contentsOf: url)
        )
        try manifest.validate()
        return manifest
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    private static func isSafeIdentifierComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 65 && scalar.value <= 90)
                || (scalar.value >= 97 && scalar.value <= 122)
                || scalar == "."
                || scalar == "_"
                || scalar == "+"
                || scalar == "-"
        }
    }
}

struct ReleaseArtifactInspection: Equatable, Sendable {
    let sha256: String
    let architectures: [String]
    let platform: InstallArtifactPlatform
}

typealias ReleaseArtifactInspector = @Sendable (
    _ artifact: InstallArtifactName,
    _ url: URL
) async throws -> ReleaseArtifactInspection

struct LiveReleaseArtifactInspector: Sendable {
    let runner: CommandRunning
    let checkCancellation: @Sendable () throws -> Void

    func inspect(
        artifact: InstallArtifactName,
        at url: URL
    ) async throws -> ReleaseArtifactInspection {
        try checkCancellation()
        let resourceValues = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard resourceValues.isRegularFile == true,
              resourceValues.isSymbolicLink != true
        else {
            throw InstallError.message(
                "install artifact is not a regular file: \(url.path)"
            )
        }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw InstallError.message(
                "install artifact is not executable: \(url.path)"
            )
        }

        let architectureOutput = try await runner.runCapture(
            ["/usr/bin/lipo", "-archs", url.path],
            env: nil,
            cwd: nil
        )
        try checkCancellation()
        let architectures = architectureOutput
            .split(whereSeparator: \Character.isWhitespace)
            .map(String.init)
            .sorted()
        guard !architectures.isEmpty else {
            throw InstallError.message(
                "failed to determine architecture for \(url.path)"
            )
        }

        let buildOutput = try await runner.runCapture(
            ["/usr/bin/vtool", "-show-build", url.path],
            env: nil,
            cwd: nil
        )
        try checkCancellation()
        let rawPlatforms = Set(
            buildOutput
                .split(whereSeparator: \Character.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.hasPrefix("platform ") }
                .map { String($0.dropFirst("platform ".count)) }
        )
        let platform: InstallArtifactPlatform
        switch rawPlatforms {
        case ["MACOS"]:
            platform = .macOS
        case ["IOSSIMULATOR"]:
            platform = .iOSSimulator
        default:
            throw InstallError.message(
                "unexpected build platform for \(url.path): \(rawPlatforms.sorted().joined(separator: ", "))"
            )
        }
        guard platform == artifact.expectedPlatform else {
            throw InstallError.message(
                "wrong build platform for \(artifact.rawValue): expected \(artifact.expectedPlatform.rawValue), got \(platform.rawValue)"
            )
        }

        try await runner.runSimple(
            ["/usr/bin/codesign", "--verify", "--strict", url.path],
            env: nil,
            cwd: nil
        )
        try checkCancellation()

        return ReleaseArtifactInspection(
            sha256: try Self.sha256(
                of: url,
                checkCancellation: checkCancellation
            ),
            architectures: architectures,
            platform: platform
        )
    }

    static func sha256(
        of url: URL,
        checkCancellation: () throws -> Void
    ) throws -> String {
        try fileSHA256Hex(
            ofFileAt: url,
            context: .artifactValidation,
            checkCancellation: checkCancellation
        )
    }
}
