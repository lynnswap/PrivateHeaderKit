package enum SimulatorPlatform: String, CaseIterable, Codable, Equatable, Sendable {
    case iOS = "iOS"
    case watchOS = "watchOS"

    package init?(coreSimulatorPlatformName: String) {
        self.init(rawValue: coreSimulatorPlatformName)
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
}
