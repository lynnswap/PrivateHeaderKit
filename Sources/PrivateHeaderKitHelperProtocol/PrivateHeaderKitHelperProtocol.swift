import Foundation

package enum PrivateHeaderKitHelperCommand: String, Sendable {
    case rawDump = "__raw-dump"
    case sharedCacheInventory = "__shared-cache-inventory"
    case deviceSource = "__device-source"
    case processImages = "__process-images"
    case recoverProcessImage = "__recover-process-image"
    case runningApplication = "__running-application"
}

/// The identity a raw-dump helper reports about its own process before it starts dumping.
///
/// A helper that later terminates on a signal leaves no other record of which process it was,
/// so the CLI keeps this identity in the failure summary for matching against a crash report.
package struct PrivateHeaderKitRawDumpProcessHandshake: Codable, Hashable, Sendable {
    package static let currentSchemaVersion = 1

    package let schemaVersion: Int
    package let invocationID: UUID
    package let processIdentifier: Int32
    package let helperStartedAtUnixMicroseconds: Int64
    package let executableName: String
    package let executableMachOUUID: UUID

    package init(
        invocationID: UUID,
        processIdentifier: Int32,
        helperStartedAtUnixMicroseconds: Int64,
        executableName: String,
        executableMachOUUID: UUID
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.invocationID = invocationID
        self.processIdentifier = processIdentifier
        self.helperStartedAtUnixMicroseconds = helperStartedAtUnixMicroseconds
        self.executableName = executableName
        self.executableMachOUUID = executableMachOUUID
    }

    package func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Decodes a handshake and checks that it belongs to the given invocation, so that a
    /// file left by another invocation is not attributed to this one.
    package static func decode(
        _ data: Data,
        expectedInvocationID: UUID
    ) throws -> Self {
        let handshake = try JSONDecoder().decode(Self.self, from: data)
        guard handshake.schemaVersion == currentSchemaVersion else {
            throw ValidationError.unsupportedSchemaVersion(
                expected: currentSchemaVersion,
                actual: handshake.schemaVersion
            )
        }
        guard handshake.invocationID == expectedInvocationID else {
            throw ValidationError.invocationIDMismatch(
                expected: expectedInvocationID,
                actual: handshake.invocationID
            )
        }
        return handshake
    }

    package enum ValidationError: Error, Equatable, Sendable {
        case unsupportedSchemaVersion(expected: Int, actual: Int)
        case invocationIDMismatch(expected: UUID, actual: UUID)
    }
}

package struct PrivateHeaderKitRawDumpDiagnostic: Codable, Hashable, Sendable {
    package static let maximumStringUTF8Count = 2_048

    package let owner: String
    package let degradation: String

    /// The strings come from the metadata of the dumped image, so they are shortened and
    /// their control characters escaped before they reach a terminal or the state database.
    package init(owner: String, degradation: String) {
        self.owner = Self.bounded(owner, fallback: "unknown Objective-C metadata owner")
        self.degradation = Self.bounded(degradation, fallback: "metadata was partially decoded")
    }

    private static func bounded(_ value: String, fallback: String) -> String {
        guard !value.isEmpty else { return fallback }
        var result = ""
        result.reserveCapacity(min(value.utf8.count, maximumStringUTF8Count))
        var byteCount = 0
        for scalar in value.unicodeScalars {
            let fragment = terminalSafeFragment(scalar)
            let fragmentByteCount = fragment.utf8.count
            guard byteCount <= maximumStringUTF8Count - fragmentByteCount else { break }
            result += fragment
            byteCount += fragmentByteCount
        }
        return result.isEmpty ? fallback : result
    }

    private static func terminalSafeFragment(_ scalar: Unicode.Scalar) -> String {
        switch scalar.value {
        case 0x0a:
            #"\n"#
        case 0x0d:
            #"\r"#
        case 0x09:
            #"\t"#
        default:
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                String(format: #"\u{%04x}"#, scalar.value)
            default:
                String(scalar)
            }
        }
    }

}

package struct PrivateHeaderKitRawDumpDiagnosticsReport: Codable, Hashable, Sendable {
    package static let currentSchemaVersion = 2
    package static let maximumDiagnosticCount = 256

    package let schemaVersion: Int
    package let producerVersion: String
    package let diagnostics: [PrivateHeaderKitRawDumpDiagnostic]
    package let omittedDiagnosticCount: UInt

    /// Keeps at most `maximumDiagnosticCount` distinct diagnostics, in a stable order, and
    /// counts the rest as omitted.
    package init(
        producerVersion: String = PrivateHeaderKitBuildInfo.version,
        diagnostics: [PrivateHeaderKitRawDumpDiagnostic],
        omittedDiagnosticCount: UInt = 0
    ) {
        let distinct = Set(diagnostics).sorted {
            ($0.owner, $0.degradation) < ($1.owner, $1.degradation)
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.producerVersion = producerVersion
        self.diagnostics = Array(distinct.prefix(Self.maximumDiagnosticCount))
        self.omittedDiagnosticCount =
            omittedDiagnosticCount + UInt(distinct.count - self.diagnostics.count)
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ValidationError.unsupportedSchemaVersion(
                expected: Self.currentSchemaVersion,
                actual: schemaVersion
            )
        }
        self.schemaVersion = schemaVersion
        self.producerVersion = try container.decode(String.self, forKey: .producerVersion)
        self.diagnostics = try container.decode(
            [PrivateHeaderKitRawDumpDiagnostic].self,
            forKey: .diagnostics
        )
        self.omittedDiagnosticCount = try container.decode(
            UInt.self,
            forKey: .omittedDiagnosticCount
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case producerVersion
        case diagnostics
        case omittedDiagnosticCount
    }

    package enum ValidationError: Error, Equatable, Sendable {
        case unsupportedSchemaVersion(expected: Int, actual: Int)
    }
}

package struct PrivateHeaderKitSharedCacheInventory: Codable, Equatable, Sendable {
    package static let currentSchemaVersion = 2

    package let schemaVersion: Int
    package let producerVersion: String
    package let cacheUUID: UUID
    /// The cache's image paths, distinct and sorted.
    package let imagePaths: [String]

    package init(
        producerVersion: String = PrivateHeaderKitBuildInfo.version,
        cacheUUID: UUID,
        imagePaths: [String]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.producerVersion = producerVersion
        self.cacheUUID = cacheUUID
        self.imagePaths = Set(imagePaths).sorted()
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ValidationError.unsupportedSchemaVersion(
                expected: Self.currentSchemaVersion,
                actual: schemaVersion
            )
        }
        self.schemaVersion = schemaVersion
        self.producerVersion = try container.decode(String.self, forKey: .producerVersion)
        self.cacheUUID = try container.decode(UUID.self, forKey: .cacheUUID)
        self.imagePaths = Set(try container.decode([String].self, forKey: .imagePaths)).sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case producerVersion
        case cacheUUID
        case imagePaths
    }
}

package extension PrivateHeaderKitSharedCacheInventory {
    enum ValidationError: Error, Equatable, CustomStringConvertible, Sendable {
        case unsupportedSchemaVersion(expected: Int, actual: Int)

        package var description: String {
            switch self {
            case .unsupportedSchemaVersion(let expected, let actual):
                "unsupported shared-cache inventory schema version \(actual); expected \(expected)"
            }
        }
    }
}
