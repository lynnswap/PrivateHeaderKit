import Foundation

extension PrivateHeaderGeneration {
    enum TargetKind: String, CaseIterable, Hashable, Sendable {
        case framework
        case privateFramework
        case systemBundle
        case usrLibDylib
        case nestedBundle
        case other
    }

    struct TargetCandidate: Hashable, Sendable {
        let identifier: String
        let displayName: String
        let kind: TargetKind
        let aliases: [String]

        init(
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

        var searchableNames: [String] {
            [displayName] + inferredAliases + aliases
        }

        private static func validateNonEmpty(_ value: String, field: String) throws {
            guard !value.isEmpty else {
                throw ValidationError.emptyComponent(field: field)
            }
        }

        private var inferredAliases: [String] {
            switch kind {
            case .usrLibDylib where !displayName.hasPrefix("/"):
                ["/usr/lib/\(displayName)"]
            default:
                []
            }
        }
    }

    enum TargetSelection: Hashable, Sendable {
        case allAvailable
        case targets([TargetCandidate])
    }

    struct TargetQuery: Hashable, Sendable {
        let rawValue: String
        let terms: [String]

        init(commaSeparated rawValue: String) throws {
            let terms = rawValue
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            try Self.validate(terms: terms)
            self.rawValue = rawValue
            self.terms = terms
        }

        var requestsAllAvailableTargets: Bool {
            terms.count == 1 && Self.allAvailableTerms.contains(Self.normalize(terms[0]))
        }

        private static let allAvailableTerms: Set<String> = [
            "all",
            "@all",
            "すべて",
        ]
        private static let systemLibraryPrefix = "/System/Library/"
        private static let usrLibPrefix = "/usr/lib/"

        private static func validate(terms: [String]) throws {
            guard !terms.isEmpty else {
                throw ValidationError.emptyComponent(field: "query")
            }

            var requestedAll = false
            for term in terms {
                guard !term.isEmpty else {
                    throw ValidationError.emptyComponent(field: "query")
                }
                let normalizedTerm = normalize(term)
                if allAvailableTerms.contains(normalizedTerm) {
                    requestedAll = true
                    continue
                }
                guard isSafeTargetSelector(term) else {
                    throw ValidationError.invalidPathComponent(field: "query", value: term)
                }
            }

            if requestedAll && terms.count > 1 {
                throw ValidationError.invalidAllTargetsCombination
            }
        }

        private static func normalize(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        private static func isSafeTargetSelector(_ value: String) -> Bool {
            guard !value.contains("\0") else { return false }
            if value.hasPrefix(systemLibraryPrefix) {
                return isValidSystemLibrarySelector(value)
            }
            if value.hasPrefix(usrLibPrefix) {
                return isValidUsrLibDylibSelector(value)
            }
            if value.hasPrefix("/") {
                return false
            }
            let components = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            return components.allSatisfy(isSafeRelativePathComponent)
        }

        private static func isValidSystemLibrarySelector(_ value: String) -> Bool {
            let relativePath = String(value.dropFirst(systemLibraryPrefix.count))
            let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            return components.allSatisfy(isSafeRelativePathComponent)
        }

        private static func isValidUsrLibDylibSelector(_ value: String) -> Bool {
            let name = String(value.dropFirst(usrLibPrefix.count))
            return isSafeRelativePathComponent(name)
                && !name.contains("/")
                && name.lowercased().hasSuffix(".dylib")
        }

        private static func isSafeRelativePathComponent(_ component: String) -> Bool {
            !component.isEmpty
                && component != "."
                && component != ".."
                && !component.contains("..")
        }
    }

    struct TargetResolver: Hashable, Sendable {
        let candidates: [TargetCandidate]

        init(candidates: [TargetCandidate]) {
            self.candidates = candidates
        }

        func resolve(_ query: TargetQuery) -> TargetResolution {
            if query.requestsAllAvailableTargets {
                return .selected(.allAvailable)
            }

            var selected: [TargetCandidate] = []
            var selectedIDs: Set<String> = []
            var ambiguities: [TargetResolution.Ambiguity] = []
            var failures: [TargetResolution.Failure] = []

            for term in query.terms {
                let matches = matches(for: term)
                switch matches.count {
                case 0:
                    failures.append(
                        TargetResolution.Failure(
                            query: term,
                            reason: .noMatch
                        )
                    )
                case 1:
                    let candidate = matches[0]
                    if selectedIDs.insert(candidate.identifier).inserted {
                        selected.append(candidate)
                    }
                default:
                    ambiguities.append(
                        TargetResolution.Ambiguity(
                            query: term,
                            candidates: matches
                        )
                    )
                }
            }

            if !ambiguities.isEmpty, !failures.isEmpty {
                return .unresolved(ambiguities: ambiguities, failures: failures)
            }
            if !failures.isEmpty {
                return .failed(failures)
            }
            if !ambiguities.isEmpty {
                return .needsDisambiguation(ambiguities)
            }
            return .selected(.targets(selected))
        }

        private func matches(for term: String) -> [TargetCandidate] {
            let normalizedTerm = Self.normalize(term)
            let exactMatches = candidates.filter { candidate in
                candidate.searchableNames.contains { Self.normalize($0) == normalizedTerm }
            }
            if !exactMatches.isEmpty {
                return exactMatches
            }

            return candidates.filter { candidate in
                candidate.searchableNames.contains { Self.normalize($0).contains(normalizedTerm) }
            }
        }

        private static func normalize(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    enum TargetResolution: Hashable, Sendable {
        case selected(TargetSelection)
        case needsDisambiguation([Ambiguity])
        case failed([Failure])
        case unresolved(ambiguities: [Ambiguity], failures: [Failure])

        struct Ambiguity: Hashable, Sendable {
            let query: String
            let candidates: [TargetCandidate]

            init(query: String, candidates: [TargetCandidate]) {
                self.query = query
                self.candidates = candidates
            }
        }

        struct Failure: Hashable, Sendable {
            let query: String
            let reason: FailureReason

            init(query: String, reason: FailureReason) {
                self.query = query
                self.reason = reason
            }
        }

        enum FailureReason: String, Hashable, Sendable {
            case noMatch
        }
    }

    enum ValidationError: Error, Equatable, CustomStringConvertible, Sendable {
        case emptyComponent(field: String)
        case invalidPathComponent(field: String, value: String)
        case invalidAllTargetsCombination

        var description: String {
            switch self {
            case .emptyComponent(let field):
                "\(field) must not be empty"
            case .invalidPathComponent(let field, let value):
                "\(field) is not safe as a path component: \(value)"
            case .invalidAllTargetsCombination:
                "all available targets cannot be combined with explicit target queries"
            }
        }
    }
}
