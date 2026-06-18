import Testing

import PrivateHeaderKitCore

@Suite
struct PrivateHeaderGenerationSourceDiscoveryTests {
    @Test func parsesAvailableIOSRuntimeSourcesAndUsesSourceLabels() throws {
        let candidates = try PrivateHeaderGeneration.SourceDiscovery.iOSRuntimeSourceCandidates(
            fromSimctlListRuntimesJSON: """
            {
              "runtimes": [
                {"name": "watchOS 27.0", "platform": "watchOS", "version": "27.0", "buildversion": "24A1", "isAvailable": true},
                {"name": "iOS 26.0", "platform": "iOS", "version": "26.0", "buildversion": "23A1", "isAvailable": false},
                {"name": "iOS Missing Build", "platform": "iOS", "version": "26.1", "isAvailable": true},
                {"name": "iOS Missing Version", "platform": "iOS", "buildversion": "23B1", "isAvailable": true},
                {
                  "name": "iOS 27.0",
                  "platform": "iOS",
                  "version": "27.0",
                  "buildversion": "24A5355q",
                  "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                  "runtimeRoot": "/runtimes/iOS-27.0",
                  "isAvailable": true
                }
              ]
            }
            """
        )

        let candidate = try #require(candidates.only)
        #expect(candidate.source.platform == .iOS)
        #expect(candidate.source.version == "27.0")
        #expect(candidate.source.build == "24A5355q")
        #expect(candidate.source.label.displayName == "iOS 27.0 (24A5355q)")
        #expect(candidate.source.label.directoryName == "iOS27.0(24A5355q)")
        #expect(candidate.runtimeName == "iOS 27.0")
        #expect(candidate.runtimeIdentifier == "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
        #expect(candidate.runtimeRoot == "/runtimes/iOS-27.0")
    }

    @Test func candidatesUseExplicitVersionBuildAndNameOrderForLatestSelection() throws {
        let candidates = try PrivateHeaderGeneration.SourceDiscovery.iOSRuntimeSourceCandidates(
            fromSimctlListRuntimesJSON: """
            {
              "runtimes": [
                {"name": "iOS 26.10 B", "platform": "iOS", "version": "26.10", "buildversion": "23Z10", "identifier": "ios-26-10-b", "isAvailable": true},
                {"name": "iOS 27.0", "platform": "iOS", "version": "27.0", "buildversion": "24A5355q", "identifier": "ios-27-0", "isAvailable": true},
                {"name": "iOS 26.2", "platform": "iOS", "version": "26.2", "buildversion": "23C54", "identifier": "ios-26-2", "isAvailable": true},
                {"name": "iOS 26.10", "platform": "iOS", "version": "26.10", "buildversion": "23Z9", "identifier": "ios-26-10-z9", "isAvailable": true},
                {"name": "iOS 26.10 A", "platform": "iOS", "version": "26.10", "buildversion": "23Z10", "identifier": "ios-26-10-a", "isAvailable": true}
              ]
            }
            """
        )

        #expect(candidates.map(\.source.label.displayName) == [
            "iOS 26.2 (23C54)",
            "iOS 26.10 (23Z9)",
            "iOS 26.10 (23Z10)",
            "iOS 27.0 (24A5355q)",
        ])
        #expect(candidates.map(\.runtimeName) == [
            "iOS 26.2",
            "iOS 26.10",
            "iOS 26.10 A",
            "iOS 27.0",
        ])

        let latest = try #require(
            PrivateHeaderGeneration.SourceDiscovery.latestIOSRuntimeSourceCandidate(from: candidates)
        )
        #expect(latest.source.label.displayName == "iOS 27.0 (24A5355q)")
    }

    @Test func duplicateRuntimeSourcesAreCanonicalizedWithoutDependingOnJSONOrder() throws {
        let firstOrder = """
        {
          "runtimes": [
            {"name": "iOS 26.2 B", "platform": "iOS", "version": "26.2", "buildversion": "23C54", "identifier": "ios-26-2-b", "isAvailable": true},
            {"name": "iOS 26.2 A", "platform": "iOS", "version": "26.2", "buildversion": "23C54", "identifier": "ios-26-2-a", "isAvailable": true}
          ]
        }
        """
        let secondOrder = """
        {
          "runtimes": [
            {"name": "iOS 26.2 A", "platform": "iOS", "version": "26.2", "buildversion": "23C54", "identifier": "ios-26-2-a", "isAvailable": true},
            {"name": "iOS 26.2 B", "platform": "iOS", "version": "26.2", "buildversion": "23C54", "identifier": "ios-26-2-b", "isAvailable": true}
          ]
        }
        """

        let first = try PrivateHeaderGeneration.SourceDiscovery.iOSRuntimeSourceCandidates(
            fromSimctlListRuntimesJSON: firstOrder
        )
        let second = try PrivateHeaderGeneration.SourceDiscovery.iOSRuntimeSourceCandidates(
            fromSimctlListRuntimesJSON: secondOrder
        )

        #expect(first == second)
        #expect(first.map(\.source.label.displayName) == ["iOS 26.2 (23C54)"])
        #expect(first.map(\.runtimeIdentifier) == ["ios-26-2-a"])
    }

    @Test func recognizesIOSRuntimeFromNameOrIdentifierWhenPlatformIsMissing() throws {
        let candidates = try PrivateHeaderGeneration.SourceDiscovery.iOSRuntimeSourceCandidates(
            fromSimctlListRuntimesJSON: """
            {
              "runtimes": [
                {"name": "iOS 26.2", "version": "26.2", "buildversion": "23C54", "isAvailable": true},
                {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "version": "27.0", "buildversion": "24A5355q", "isAvailable": true}
              ]
            }
            """
        )

        #expect(candidates.map(\.source.label.displayName) == [
            "iOS 26.2 (23C54)",
            "iOS 27.0 (24A5355q)",
        ])
        #expect(candidates.map(\.runtimeName) == [
            "iOS 26.2",
            "iOS 27.0 (24A5355q)",
        ])
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
