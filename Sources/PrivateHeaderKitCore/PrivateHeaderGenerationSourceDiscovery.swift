import Foundation

public extension PrivateHeaderGeneration {
    struct SourceCandidate: Hashable, Sendable {
        public let source: Source
        public let runtimeName: String
        public let runtimeIdentifier: String?
        public let runtimeRoot: String?

        public init(
            source: Source,
            runtimeName: String? = nil,
            runtimeIdentifier: String? = nil,
            runtimeRoot: String? = nil
        ) {
            self.source = source
            self.runtimeName = runtimeName.trimmedNonEmpty ?? source.label.displayName
            self.runtimeIdentifier = runtimeIdentifier.trimmedNonEmpty
            self.runtimeRoot = runtimeRoot.trimmedNonEmpty
        }
    }

    enum SourceDiscovery {
        public static func iOSRuntimeSourceCandidates(
            fromSimctlListRuntimesJSON json: String
        ) throws -> [SourceCandidate] {
            try iOSRuntimeSourceCandidates(fromSimctlListRuntimesJSON: Data(json.utf8))
        }

        public static func iOSRuntimeSourceCandidates(
            fromSimctlListRuntimesJSON data: Data
        ) throws -> [SourceCandidate] {
            let decoded = try JSONDecoder().decode(SimctlRuntimeList.self, from: data)
            let candidates = try (decoded.runtimes ?? []).compactMap { entry -> SourceCandidate? in
                guard entry.isAvailableForUse, entry.isIOSRuntime else {
                    return nil
                }
                guard let version = entry.version.trimmedNonEmpty,
                      let build = entry.buildversion.trimmedNonEmpty else {
                    return nil
                }

                return SourceCandidate(
                    source: try Source(platform: .iOS, version: version, build: build),
                    runtimeName: entry.name,
                    runtimeIdentifier: entry.identifier,
                    runtimeRoot: entry.runtimeRoot
                )
            }

            return deduplicatedBySource(sortedIOSRuntimeSourceCandidates(candidates))
        }

        public static func sortedIOSRuntimeSourceCandidates(
            _ candidates: [SourceCandidate]
        ) -> [SourceCandidate] {
            candidates.sorted(by: SourceCandidateOrdering.isOrderedBefore)
        }

        public static func latestIOSRuntimeSourceCandidate(
            from candidates: [SourceCandidate]
        ) -> SourceCandidate? {
            sortedIOSRuntimeSourceCandidates(candidates).last
        }

        private static func deduplicatedBySource(
            _ candidates: [SourceCandidate]
        ) -> [SourceCandidate] {
            var seenSources: Set<Source> = []
            var uniqueCandidates: [SourceCandidate] = []
            for candidate in candidates where seenSources.insert(candidate.source).inserted {
                uniqueCandidates.append(candidate)
            }
            return uniqueCandidates
        }
    }
}

private struct SimctlRuntimeList: Decodable {
    struct RuntimeEntry: Decodable {
        let name: String?
        let platform: String?
        let version: String?
        let buildversion: String?
        let identifier: String?
        let runtimeRoot: String?
        let isAvailable: Bool?
        let availability: String?

        var isAvailableForUse: Bool {
            if let isAvailable {
                return isAvailable
            }

            guard let availability = availability.trimmedNonEmpty?.lowercased() else {
                return false
            }
            return availability == "available" || availability == "(available)"
        }

        var isIOSRuntime: Bool {
            if let platform = platform.trimmedNonEmpty {
                return platform.caseInsensitiveCompare("iOS") == .orderedSame
            }
            if let name = name.trimmedNonEmpty {
                let lowercasedName = name.lowercased()
                return lowercasedName == "ios" || lowercasedName.hasPrefix("ios ")
            }
            if let identifier = identifier.trimmedNonEmpty {
                return identifier.contains(".SimRuntime.iOS-")
                    || identifier.hasSuffix(".SimRuntime.iOS")
            }
            return false
        }
    }

    let runtimes: [RuntimeEntry]?
}

private enum SourceCandidateOrdering {
    static func isOrderedBefore(
        _ lhs: PrivateHeaderGeneration.SourceCandidate,
        _ rhs: PrivateHeaderGeneration.SourceCandidate
    ) -> Bool {
        compare(lhs, rhs) == .orderedAscending
    }

    private static func compare(
        _ lhs: PrivateHeaderGeneration.SourceCandidate,
        _ rhs: PrivateHeaderGeneration.SourceCandidate
    ) -> ComparisonResult {
        compareSortTokens(lhs.source.version, rhs.source.version)
            .orElse(compareSortTokens(lhs.source.build ?? "", rhs.source.build ?? ""))
            .orElse(compareSortTokens(lhs.runtimeName, rhs.runtimeName))
            .orElse(compareOptionalSortStrings(lhs.runtimeIdentifier, rhs.runtimeIdentifier))
            .orElse(compareOptionalSortStrings(lhs.runtimeRoot, rhs.runtimeRoot))
    }

    private static func compareOptionalSortStrings(_ lhs: String?, _ rhs: String?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil):
            return .orderedSame
        case (.some, nil):
            return .orderedAscending
        case (nil, .some):
            return .orderedDescending
        case let (.some(lhs), .some(rhs)):
            return compareSortTokens(lhs, rhs)
        }
    }

    private static func compareSortTokens(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsTokens = NaturalSortToken.tokenize(lhs)
        let rhsTokens = NaturalSortToken.tokenize(rhs)
        let count = min(lhsTokens.count, rhsTokens.count)

        for index in 0..<count {
            if lhsTokens[index] < rhsTokens[index] {
                return .orderedAscending
            }
            if rhsTokens[index] < lhsTokens[index] {
                return .orderedDescending
            }
        }

        if lhsTokens.count == rhsTokens.count {
            return .orderedSame
        }
        return lhsTokens.count < rhsTokens.count ? .orderedAscending : .orderedDescending
    }
}

private enum NaturalSortToken: Comparable {
    case number(Int)
    case text(String)

    static func tokenize(_ value: String) -> [NaturalSortToken] {
        var tokens: [NaturalSortToken] = []
        var current = ""
        var currentIsNumber: Bool?

        for scalar in value.unicodeScalars {
            let isNumber = CharacterSet.decimalDigits.contains(scalar)
            if currentIsNumber == nil || currentIsNumber == isNumber {
                current.unicodeScalars.append(scalar)
                currentIsNumber = isNumber
            } else {
                tokens.append(token(from: current, isNumber: currentIsNumber == true))
                current = String(scalar)
                currentIsNumber = isNumber
            }
        }

        if let currentIsNumber {
            tokens.append(token(from: current, isNumber: currentIsNumber))
        }

        return tokens
    }

    static func < (lhs: NaturalSortToken, rhs: NaturalSortToken) -> Bool {
        switch (lhs, rhs) {
        case let (.number(lhs), .number(rhs)):
            return lhs < rhs
        case let (.text(lhs), .text(rhs)):
            return lhs.lowercased() < rhs.lowercased()
        case (.number, .text):
            return true
        case (.text, .number):
            return false
        }
    }

    private static func token(from value: String, isNumber: Bool) -> NaturalSortToken {
        if isNumber, let number = Int(value) {
            return .number(number)
        }
        return .text(value)
    }
}

private extension ComparisonResult {
    func orElse(_ fallback: @autoclosure () -> ComparisonResult) -> ComparisonResult {
        self == .orderedSame ? fallback() : self
    }
}

private extension Optional where Wrapped == String {
    var trimmedNonEmpty: String? {
        switch self {
        case .none:
            return nil
        case .some(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}
