package enum SimulatorPlatform: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case iOS = "iOS"
    case watchOS = "watchOS"

    package init?(
        coreSimulatorPlatformName: String?,
        runtimeName: String?,
        runtimeIdentifier: String?
    ) {
        if let explicitPlatform = Self.trimmedNonEmpty(coreSimulatorPlatformName) {
            guard let platform = Self.allCases.first(where: {
                $0.coreSimulatorPlatformName.caseInsensitiveCompare(explicitPlatform)
                    == .orderedSame
            }) else {
                return nil
            }
            self = platform
            return
        }

        if let normalizedName = Self.trimmedNonEmpty(runtimeName)?.lowercased() {
            if let platform = Self.allCases.first(where: {
                let normalizedPlatform = $0.userFacingSourceName.lowercased()
                return normalizedName == normalizedPlatform
                    || normalizedName.hasPrefix(normalizedPlatform + " ")
            }) {
                self = platform
                return
            }
        }

        if let identifier = Self.trimmedNonEmpty(runtimeIdentifier),
           let platform = Self.allCases.first(where: {
               let component = ".SimRuntime.\($0.coreSimulatorPlatformName)"
               return identifier.contains(component + "-")
                   || identifier.hasSuffix(component)
           })
        {
            self = platform
            return
        }
        return nil
    }

    package var coreSimulatorPlatformName: String { rawValue }

    package var sdkName: String {
        switch self {
        case .iOS:
            "iphonesimulator"
        case .watchOS:
            "watchsimulator"
        }
    }

    package var targetOSName: String {
        switch self {
        case .iOS:
            "ios"
        case .watchOS:
            "watchos"
        }
    }

    package func swiftPMTriple(architecture: String) -> String {
        "\(architecture)-apple-\(targetOSName)-simulator"
    }

    package var preferredDeviceFamily: String {
        switch self {
        case .iOS:
            "iPhone"
        case .watchOS:
            "Apple Watch"
        }
    }

    package var userFacingSourceName: String { rawValue }

    package var userFacingSimulatorName: String {
        "\(userFacingSourceName) Simulator"
    }

    package var sortIndex: Int {
        switch self {
        case .iOS:
            0
        case .watchOS:
            1
        }
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }
}
