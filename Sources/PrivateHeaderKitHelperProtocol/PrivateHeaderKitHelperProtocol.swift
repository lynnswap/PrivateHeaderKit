import Foundation

package enum PrivateHeaderKitHelperCommand: String, Sendable {
    case rawDump = "__raw-dump"
    case sharedCacheInventory = "__shared-cache-inventory"
}

package enum PrivateHeaderKitProducerVersion {
    package static let maximumUTF8Count = 256

    package static func validated(_ value: String) throws -> String {
        guard !value.isEmpty,
              value.utf8.count <= maximumUTF8Count,
              value.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.properties.generalCategory {
                  case .control, .format, .lineSeparator, .paragraphSeparator:
                      false
                  default:
                      true
                  }
              })
        else {
            throw ValidationError.invalid
        }
        return value
    }

    package enum ValidationError: Error, Equatable, Sendable {
        case invalid
    }
}

package struct PrivateHeaderKitRawDumpDiagnostic: Codable, Hashable, Sendable {
    package static let maximumStringUTF8Count = 2_048

    package let owner: String
    package let degradation: String

    package init(owner: String, degradation: String) {
        self.owner = Self.bounded(owner, fallback: "unknown Objective-C metadata owner")
        self.degradation = Self.bounded(degradation, fallback: "metadata was partially decoded")
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let owner = try container.decode(String.self, forKey: .owner)
        let degradation = try container.decode(String.self, forKey: .degradation)
        guard !owner.isEmpty,
              owner.utf8.count <= Self.maximumStringUTF8Count,
              Self.terminalSafe(owner) == owner
        else {
            throw ValidationError.invalidString(field: "owner")
        }
        guard !degradation.isEmpty,
              degradation.utf8.count <= Self.maximumStringUTF8Count,
              Self.terminalSafe(degradation) == degradation
        else {
            throw ValidationError.invalidString(field: "degradation")
        }
        self.owner = owner
        self.degradation = degradation
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

    private static func terminalSafe(_ value: String) -> String {
        value.unicodeScalars.reduce(into: "") { result, scalar in
            result += terminalSafeFragment(scalar)
        }
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

    private enum CodingKeys: String, CodingKey {
        case owner
        case degradation
    }

    package enum ValidationError: Error, Equatable, Sendable {
        case invalidString(field: String)
    }
}

package struct PrivateHeaderKitRawDumpDiagnosticsReport: Codable, Hashable, Sendable {
    package static let currentSchemaVersion = 2
    package static let maximumDiagnosticCount = 256
    package static let maximumEncodedByteCount = 4 * 1_024 * 1_024

    package let schemaVersion: Int
    package let producerVersion: String
    package let diagnostics: [PrivateHeaderKitRawDumpDiagnostic]
    package let omittedDiagnosticCount: UInt

    package init(
        producerVersion: String = PrivateHeaderKitBuildInfo.version,
        diagnostics: [PrivateHeaderKitRawDumpDiagnostic],
        omittedDiagnosticCount: UInt = 0
    ) {
        let normalized = Array(Set(diagnostics)).sorted(by: Self.areInIncreasingOrder)
        precondition(
            (try? PrivateHeaderKitProducerVersion.validated(producerVersion)) != nil,
            "producer version must satisfy the helper wire contract"
        )
        self.schemaVersion = Self.currentSchemaVersion
        self.producerVersion = producerVersion
        self.diagnostics = Array(normalized.prefix(Self.maximumDiagnosticCount))
        let existingOmittedCount = omittedDiagnosticCount
        let newlyOmittedCount = UInt(max(0, normalized.count - Self.maximumDiagnosticCount))
        let (combinedOmittedCount, overflow) = existingOmittedCount.addingReportingOverflow(
            newlyOmittedCount
        )
        self.omittedDiagnosticCount = overflow ? UInt.max : combinedOmittedCount
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
        let producerVersion = try PrivateHeaderKitProducerVersion.validated(
            container.decode(String.self, forKey: .producerVersion)
        )
        let diagnostics = try container.decode(
            [PrivateHeaderKitRawDumpDiagnostic].self,
            forKey: .diagnostics
        )
        guard diagnostics.count <= Self.maximumDiagnosticCount else {
            throw ValidationError.excessiveDiagnosticCount(
                actual: diagnostics.count,
                maximum: Self.maximumDiagnosticCount
            )
        }
        let omittedDiagnosticCount = try container.decode(
            UInt.self,
            forKey: .omittedDiagnosticCount
        )
        let normalized = Array(Set(diagnostics)).sorted(by: Self.areInIncreasingOrder)
        guard diagnostics == normalized else {
            throw ValidationError.nonCanonicalDiagnostics
        }
        self.schemaVersion = schemaVersion
        self.producerVersion = producerVersion
        self.diagnostics = diagnostics
        self.omittedDiagnosticCount = omittedDiagnosticCount
    }

    private static func areInIncreasingOrder(
        _ lhs: PrivateHeaderKitRawDumpDiagnostic,
        _ rhs: PrivateHeaderKitRawDumpDiagnostic
    ) -> Bool {
        if lhs.owner != rhs.owner { return lhs.owner < rhs.owner }
        return lhs.degradation < rhs.degradation
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case producerVersion
        case diagnostics
        case omittedDiagnosticCount
    }

    package enum ValidationError: Error, Equatable, Sendable {
        case unsupportedSchemaVersion(expected: Int, actual: Int)
        case excessiveDiagnosticCount(actual: Int, maximum: Int)
        case nonCanonicalDiagnostics
    }
}

package struct PrivateHeaderKitSharedCacheInventory: Codable, Equatable, Sendable {
    package static let currentSchemaVersion = 2

    package let schemaVersion: Int
    package let producerVersion: String
    package let cacheUUID: UUID
    package let imagePaths: [String]

    package init(
        producerVersion: String = PrivateHeaderKitBuildInfo.version,
        cacheUUID: UUID,
        imagePaths: [String]
    ) throws {
        self.schemaVersion = Self.currentSchemaVersion
        self.producerVersion = try PrivateHeaderKitProducerVersion.validated(producerVersion)
        self.cacheUUID = cacheUUID
        self.imagePaths = try Self.validatedImagePaths(imagePaths)
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
        self.producerVersion = try PrivateHeaderKitProducerVersion.validated(
            container.decode(String.self, forKey: .producerVersion)
        )
        self.cacheUUID = try container.decode(UUID.self, forKey: .cacheUUID)
        self.imagePaths = try Self.validatedImagePaths(
            container.decode([String].self, forKey: .imagePaths)
        )
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(producerVersion, forKey: .producerVersion)
        try container.encode(cacheUUID, forKey: .cacheUUID)
        try container.encode(imagePaths, forKey: .imagePaths)
    }

    private static func validatedImagePaths(_ paths: [String]) throws -> [String] {
        let validated = try paths.map { path in
            guard isAbsoluteLogicalPath(path) else {
                throw ValidationError.invalidImagePath(path)
            }
            return path
        }
        return Array(Set(validated)).sorted()
    }

    private static func isAbsoluteLogicalPath(_ path: String) -> Bool {
        guard path.first == "/", path.count > 1 else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.dropFirst().contains { component in
            component.isEmpty || component == "." || component == ".."
        }
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
        case invalidImagePath(String)

        package var description: String {
            switch self {
            case .unsupportedSchemaVersion(let expected, let actual):
                "unsupported shared-cache inventory schema version \(actual); expected \(expected)"
            case .invalidImagePath(let path):
                "shared-cache image path must be an absolute logical path: \(path)"
            }
        }
    }
}
