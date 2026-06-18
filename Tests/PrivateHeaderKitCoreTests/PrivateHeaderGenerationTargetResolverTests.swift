import Testing

@testable import PrivateHeaderKitCore

@Suite
struct PrivateHeaderGenerationTargetResolverTests {
    @Test func commaSeparatedQueryResolvesTargetsInStableDeduplicatedOrder() throws {
        let resolver = PrivateHeaderGeneration.TargetResolver(
            candidates: try [
                candidate("UIKitCore", kind: .framework),
                candidate("SwiftUI", kind: .framework),
                candidate("SafariShared", kind: .privateFramework),
            ]
        )
        let query = try PrivateHeaderGeneration.TargetQuery(
            commaSeparated: "SwiftUI, UIKitCore, SwiftUI"
        )

        #expect(
            resolver.resolve(query) == .selected(
                .targets(
                    try [
                        candidate("SwiftUI", kind: .framework),
                        candidate("UIKitCore", kind: .framework),
                    ]
                )
            )
        )
    }

    @Test func exactMatchWinsOverPartialMatches() throws {
        let exact = try candidate("UIKit", kind: .framework)
        let resolver = PrivateHeaderGeneration.TargetResolver(
            candidates: try [
                candidate("UIKitCore", kind: .framework),
                exact,
                candidate("UIKitServices", kind: .privateFramework),
            ]
        )
        let query = try PrivateHeaderGeneration.TargetQuery(commaSeparated: "UIKit")

        #expect(resolver.resolve(query) == .selected(.targets([exact])))
    }

    @Test func partialMatchCanResolveSingleCandidate() throws {
        let candidate = try candidate("SafariShared", kind: .privateFramework)
        let resolver = PrivateHeaderGeneration.TargetResolver(
            candidates: [
                candidate,
            ]
        )
        let query = try PrivateHeaderGeneration.TargetQuery(commaSeparated: "safari")

        #expect(resolver.resolve(query) == .selected(.targets([candidate])))
    }

    @Test func partialMatchSearchesOnlyNamesWithoutPathSeparators() throws {
        let framework = try candidate("UIKit", kind: .framework)
        let systemBundle = try candidate(
            "PreferenceBundles/Foo.bundle",
            kind: .systemBundle,
            aliases: ["/System/Library/PreferenceBundles/Foo.bundle"]
        )
        let dylib = try candidate(
            "libobjc.A.dylib",
            kind: .usrLibDylib,
            aliases: ["usr/lib/libobjc.A.dylib"]
        )
        let resolver = PrivateHeaderGeneration.TargetResolver(
            candidates: [
                framework,
                systemBundle,
                dylib,
            ]
        )

        #expect(
            resolver.resolve(try PrivateHeaderGeneration.TargetQuery(commaSeparated: "Kit"))
                == .selected(.targets([framework]))
        )
        #expect(
            resolver.resolve(try PrivateHeaderGeneration.TargetQuery(commaSeparated: "PreferenceBundles/Foo.bundle"))
                == .selected(.targets([systemBundle]))
        )
        #expect(
            resolver.resolve(
                try PrivateHeaderGeneration.TargetQuery(commaSeparated: "/System/Library/PreferenceBundles/Foo.bundle")
            ) == .selected(.targets([systemBundle]))
        )
        #expect(
            resolver.resolve(try PrivateHeaderGeneration.TargetQuery(commaSeparated: "PreferenceBundles"))
                == .failed([
                    PrivateHeaderGeneration.TargetResolution.Failure(
                        query: "PreferenceBundles",
                        reason: .noMatch
                    ),
                ])
        )
        #expect(
            resolver.resolve(try PrivateHeaderGeneration.TargetQuery(commaSeparated: "usr/lib"))
                == .failed([
                    PrivateHeaderGeneration.TargetResolution.Failure(
                        query: "usr/lib",
                        reason: .noMatch
                    ),
                ])
        )
    }

    @Test func ambiguousPartialMatchReturnsCandidatesForUISelection() throws {
        let candidates = try [
            candidate("UIKitCore", kind: .framework),
            candidate("UIKitServices", kind: .privateFramework),
        ]
        let resolver = PrivateHeaderGeneration.TargetResolver(candidates: candidates)
        let query = try PrivateHeaderGeneration.TargetQuery(commaSeparated: "UIKit")

        #expect(
            resolver.resolve(query) == .needsDisambiguation(
                [
                    PrivateHeaderGeneration.TargetResolution.Ambiguity(
                        query: "UIKit",
                        candidates: candidates
                    ),
                ]
            )
        )
    }

    @Test func noMatchReturnsStructuredFailure() throws {
        let resolver = PrivateHeaderGeneration.TargetResolver(
            candidates: try [
                candidate("SwiftUI", kind: .framework),
            ]
        )
        let query = try PrivateHeaderGeneration.TargetQuery(commaSeparated: "NoSuchTarget")

        #expect(
            resolver.resolve(query) == .failed(
                [
                    PrivateHeaderGeneration.TargetResolution.Failure(
                        query: "NoSuchTarget",
                        reason: .noMatch
                    ),
                ]
            )
        )
    }

    @Test func mixedAmbiguousAndMissingTermsKeepBothStructuredResults() throws {
        let ambiguousCandidates = try [
            candidate("UIKitCore", kind: .framework),
            candidate("UIKitServices", kind: .privateFramework),
        ]
        let resolver = PrivateHeaderGeneration.TargetResolver(candidates: ambiguousCandidates)
        let query = try PrivateHeaderGeneration.TargetQuery(commaSeparated: "UIKit, NoSuchTarget")

        #expect(
            resolver.resolve(query) == .unresolved(
                ambiguities: [
                    PrivateHeaderGeneration.TargetResolution.Ambiguity(
                        query: "UIKit",
                        candidates: ambiguousCandidates
                    ),
                ],
                failures: [
                    PrivateHeaderGeneration.TargetResolution.Failure(
                        query: "NoSuchTarget",
                        reason: .noMatch
                    ),
                ]
            )
        )
    }

    @Test func allAvailableQuerySupportsEnglishAndJapaneseAliases() throws {
        let resolver = PrivateHeaderGeneration.TargetResolver(candidates: [])

        #expect(
            resolver.resolve(try PrivateHeaderGeneration.TargetQuery(commaSeparated: "all"))
                == .selected(.allAvailable)
        )
        #expect(
            resolver.resolve(try PrivateHeaderGeneration.TargetQuery(commaSeparated: "すべて"))
                == .selected(.allAvailable)
        )
        #expect(
            resolver.resolve(try PrivateHeaderGeneration.TargetQuery(commaSeparated: "@all"))
                == .selected(.allAvailable)
        )
    }

    @Test func allAvailableCannotBeMixedWithExplicitQueries() throws {
        #expect(throws: PrivateHeaderGeneration.ValidationError.self) {
            _ = try PrivateHeaderGeneration.TargetQuery(commaSeparated: "all, UIKitCore")
        }
    }

    @Test func queryRejectsPathUnsafeTerms() throws {
        #expect(throws: PrivateHeaderGeneration.ValidationError.self) {
            _ = try PrivateHeaderGeneration.TargetQuery(commaSeparated: "../UIKitCore")
        }

        #expect(throws: PrivateHeaderGeneration.ValidationError.self) {
            _ = try PrivateHeaderGeneration.TargetQuery(commaSeparated: "/tmp/libobjc.A.dylib")
        }

        #expect(throws: PrivateHeaderGeneration.ValidationError.self) {
            _ = try PrivateHeaderGeneration.TargetQuery(
                commaSeparated: "/System/Library/PreferenceBundles/../Foo.bundle"
            )
        }

        #expect(throws: PrivateHeaderGeneration.ValidationError.self) {
            _ = try PrivateHeaderGeneration.TargetQuery(commaSeparated: "PreferenceBundles/./Foo.bundle")
        }

        #expect(throws: PrivateHeaderGeneration.ValidationError.self) {
            _ = try PrivateHeaderGeneration.TargetQuery(commaSeparated: "/usr/lib/subdir/libobjc.A.dylib")
        }
    }

    @Test func relativeSystemLibraryPathSelectorCanResolveCandidate() throws {
        let candidate = try candidate(
            "PreferenceBundles/Foo.bundle",
            kind: .systemBundle
        )
        let resolver = PrivateHeaderGeneration.TargetResolver(candidates: [candidate])
        let query = try PrivateHeaderGeneration.TargetQuery(commaSeparated: "PreferenceBundles/Foo.bundle")

        #expect(resolver.resolve(query) == .selected(.targets([candidate])))
    }

    @Test func absoluteSystemLibraryPathAliasCanResolveCandidate() throws {
        let candidate = try candidate(
            "PreferenceBundles/Foo.bundle",
            kind: .systemBundle,
            aliases: ["/System/Library/PreferenceBundles/Foo.bundle"]
        )
        let resolver = PrivateHeaderGeneration.TargetResolver(candidates: [candidate])
        let query = try PrivateHeaderGeneration.TargetQuery(
            commaSeparated: "/System/Library/PreferenceBundles/Foo.bundle"
        )

        #expect(resolver.resolve(query) == .selected(.targets([candidate])))
    }

    @Test func usrLibDylibPathSelectorCanResolveByInferredAlias() throws {
        let candidate = try candidate(
            "libobjc.A.dylib",
            kind: .usrLibDylib
        )
        let resolver = PrivateHeaderGeneration.TargetResolver(candidates: [candidate])
        let query = try PrivateHeaderGeneration.TargetQuery(commaSeparated: "/usr/lib/libobjc.A.dylib")

        #expect(resolver.resolve(query) == .selected(.targets([candidate])))
    }

    @Test func candidatesKeepKindMetadataOutOfUserFacingSelectionRequirements() throws {
        let resolver = PrivateHeaderGeneration.TargetResolver(
            candidates: try [
                candidate(
                    "libobjc.A.dylib",
                    kind: .usrLibDylib,
                    aliases: ["objc runtime"]
                ),
            ]
        )
        let query = try PrivateHeaderGeneration.TargetQuery(commaSeparated: "objc runtime")

        #expect(
            resolver.resolve(query) == .selected(
                .targets(
                    try [
                        candidate(
                            "libobjc.A.dylib",
                            kind: .usrLibDylib,
                            aliases: ["objc runtime"]
                        ),
                    ]
                )
            )
        )
    }
}

private func candidate(
    _ displayName: String,
    kind: PrivateHeaderGeneration.TargetKind,
    aliases: [String] = []
) throws -> PrivateHeaderGeneration.TargetCandidate {
    try PrivateHeaderGeneration.TargetCandidate(
        identifier: "target.\(displayName)",
        displayName: displayName,
        kind: kind,
        aliases: aliases
    )
}
