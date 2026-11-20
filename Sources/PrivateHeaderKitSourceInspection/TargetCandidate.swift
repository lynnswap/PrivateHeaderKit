package enum TargetKind: String, Codable, CaseIterable, Hashable, Sendable {
    case framework
    case privateFramework
    case systemBundle
    case usrLibDylib
    case nestedBundle
    case other
    case application
}

package struct TargetCandidate: Codable, Hashable, Sendable {
    package let identifier: String
    package let displayName: String
    package let kind: TargetKind
    package let aliases: [String]

    package init(
        identifier: String,
        displayName: String,
        kind: TargetKind,
        aliases: [String] = []
    ) throws {
        try Self.validateNonEmpty(identifier, field: "identifier")
        try Self.validateNonEmpty(displayName, field: "displayName")
        self.identifier = identifier
        self.displayName = displayName
        self.kind = kind
        self.aliases = aliases.filter { !$0.isEmpty }
    }

    package var searchableNames: [String] {
        [displayName] + inferredAliases + aliases
    }

    package var partialSearchableNames: [String] {
        ([displayName] + aliases).filter(Self.isPartialSearchableName)
    }

    private static func validateNonEmpty(_ value: String, field: String) throws {
        guard !value.isEmpty else {
            throw ValidationError.emptyComponent(field: field)
        }
    }

    private static func isPartialSearchableName(_ value: String) -> Bool {
        !value.contains("/")
    }

    private var inferredAliases: [String] {
        switch kind {
        case .usrLibDylib where !displayName.hasPrefix("/"):
            ["/usr/lib/\(displayName)"]
        default:
            []
        }
    }

    package enum ValidationError: Error, Equatable, CustomStringConvertible, Sendable {
        case emptyComponent(field: String)

        package var description: String {
            switch self {
            case .emptyComponent(let field):
                "\(field) must not be empty"
            }
        }
    }
}
