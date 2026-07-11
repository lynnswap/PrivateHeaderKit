import Foundation
import PrivateHeaderKitTestSupport
import Testing

@testable import PrivateHeaderKitTooling

@Suite
struct ToolCompatibilityIdentityTests {
    @Test func installedIdentityUsesExecutableContentsInsteadOfDirectoryName() throws {
        let root = try makeIdentityFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("privateheaderkit-raw-helper")
        try writeExecutable("first", to: helper)

        let first = try captureToolArtifactSnapshot(
            runningExecutableIdentity: "macho-uuid:cli",
            artifacts: [ToolArtifactInput(role: "host-helper", url: helper)],
            fileManager: .default
        )
        try writeExecutable("second", to: helper)
        let second = try captureToolArtifactSnapshot(
            runningExecutableIdentity: "macho-uuid:cli",
            artifacts: [ToolArtifactInput(role: "host-helper", url: helper)],
            fileManager: .default
        )

        #expect(first != second)
        #expect(first.compatibilityIdentity.hasPrefix("phk-tool-v1:artifacts:"))
    }

    @Test func SwiftPMIdentityTracksSelectedInputsButNotGeneratedOutput() async throws {
        let fixture = try makeSwiftPMIdentityFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runner = await identityRunner(description: fixture.packageDescription)
        let context = identityContext(repoRoot: fixture.root)

        let first = try await captureSwiftPMToolSnapshot(
            context: context,
            runner: runner,
            fileManager: .default
        )
        let output = fixture.root.appendingPathComponent("out/Generated.h")
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("generated".utf8).write(to: output)
        let afterOutput = try await captureSwiftPMToolSnapshot(
            context: context,
            runner: runner,
            fileManager: .default
        )
        #expect(afterOutput == first)

        try Data("changed source".utf8).write(to: fixture.source)
        let afterSource = try await captureSwiftPMToolSnapshot(
            context: context,
            runner: runner,
            fileManager: .default
        )
        #expect(afterSource != first)
    }

    @Test func SwiftPMIdentityTracksClangHeadersAndRunningExecutable() async throws {
        let fixture = try makeSwiftPMIdentityFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runner = await identityRunner(description: fixture.packageDescription)
        let firstContext = identityContext(
            repoRoot: fixture.root,
            runningExecutableIdentity: "macho-uuid:first"
        )
        let first = try await captureSwiftPMToolSnapshot(
            context: firstContext,
            runner: runner,
            fileManager: .default
        )

        try Data("changed header".utf8).write(to: fixture.header)
        let afterHeader = try await captureSwiftPMToolSnapshot(
            context: firstContext,
            runner: runner,
            fileManager: .default
        )
        #expect(afterHeader != first)

        try Data("header".utf8).write(to: fixture.header)
        let afterExecutable = try await captureSwiftPMToolSnapshot(
            context: identityContext(
                repoRoot: fixture.root,
                runningExecutableIdentity: "macho-uuid:second"
            ),
            runner: runner,
            fileManager: .default
        )
        #expect(afterExecutable != first)
    }

    @Test func SwiftPMIdentityCanonicalizesResolvedPinOrder() async throws {
        let fixture = try makeSwiftPMIdentityFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runner = await identityRunner(description: fixture.packageDescription)
        let context = identityContext(repoRoot: fixture.root)
        let first = try await captureSwiftPMToolSnapshot(
            context: context,
            runner: runner,
            fileManager: .default
        )
        try Data(resolvedFixture(reversed: true).utf8).write(
            to: fixture.root.appendingPathComponent("Package.resolved")
        )
        let reordered = try await captureSwiftPMToolSnapshot(
            context: context,
            runner: runner,
            fileManager: .default
        )
        #expect(reordered == first)
    }

    @Test func SwiftPMIdentityRejectsDirtyResolvedDependencyCheckout() async throws {
        let fixture = try makeSwiftPMIdentityFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let revision = String(repeating: "d", count: 40)
        try Data("""
        {"pins":[{"identity":"dep","kind":"remoteSourceControl","location":"https://example.com/dep","state":{"revision":"\(revision)","version":"1.0.0"}}],"version":3}
        """.utf8).write(to: fixture.root.appendingPathComponent("Package.resolved"))
        let dependencyPath = fixture.root.appendingPathComponent(".build/checkouts/dep").path
        let runner = await identityRunner(description: fixture.packageDescription)
        await runner.setCaptureOutput(
            #"{"targets":[{"name":"Helper","dependencies":[{"product":["DepProduct","Dep",null,null]}]},{"name":"Runtime","dependencies":[]}]}"#,
            for: ["swift", "package", "dump-package"]
        )
        await runner.setCaptureOutput(
            """
            {"identity":"root","path":"\(fixture.root.path)","dependencies":[{"identity":"dep","path":"\(dependencyPath)","dependencies":[]}]}
            """,
            for: [
                "swift", "package", "--force-resolved-versions",
                "show-dependencies", "--format", "json",
            ]
        )
        let statusCommand = [
            "git", "-C", dependencyPath,
            "status", "--porcelain=v2", "--branch", "-z",
            "--untracked-files=all",
        ]
        await runner.setCaptureOutputs(
            [
                "# branch.oid \(revision)\0# branch.head (detached)\0",
                "# branch.oid \(revision)\0# branch.head (detached)\0? Local.swift\0",
            ],
            for: statusCommand
        )
        let context = identityContext(repoRoot: fixture.root)

        _ = try await captureSwiftPMToolSnapshot(
            context: context,
            runner: runner,
            fileManager: .default
        )
        await #expect(throws: ToolingError.self) {
            _ = try await captureSwiftPMToolSnapshot(
                context: context,
                runner: runner,
                fileManager: .default
            )
        }
    }
}

private struct SwiftPMIdentityFixture {
    let root: URL
    let source: URL
    let header: URL
    let packageDescription: String
}

private func makeSwiftPMIdentityFixture() throws -> SwiftPMIdentityFixture {
    let root = try makeIdentityFixtureRoot()
    let helperDirectory = root.appendingPathComponent("Sources/Helper", isDirectory: true)
    let runtimeDirectory = root.appendingPathComponent("Sources/Runtime", isDirectory: true)
    try FileManager.default.createDirectory(
        at: helperDirectory,
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: runtimeDirectory.appendingPathComponent("include", isDirectory: true),
        withIntermediateDirectories: true
    )
    let source = helperDirectory.appendingPathComponent("main.swift")
    let header = runtimeDirectory.appendingPathComponent("include/Runtime.h")
    try Data("source".utf8).write(to: source)
    try Data("header".utf8).write(to: header)
    try Data("// manifest".utf8).write(
        to: root.appendingPathComponent("Package.swift")
    )
    try Data(resolvedFixture(reversed: false).utf8).write(
        to: root.appendingPathComponent("Package.resolved")
    )
    let description = """
    {
      "targets": [
        {
          "name": "Helper",
          "path": "Sources/Helper",
          "product_memberships": ["privateheaderkit-raw-helper"]
        },
        {
          "name": "Runtime",
          "path": "Sources/Runtime",
          "product_memberships": ["privateheaderkit-raw-helper"]
        },
        {
          "name": "Unrelated",
          "path": "Sources/Unrelated",
          "product_memberships": ["privateheaderkit"]
        }
      ]
    }
    """
    return SwiftPMIdentityFixture(
        root: root,
        source: source,
        header: header,
        packageDescription: description
    )
}

private func identityContext(
    repoRoot: URL,
    runningExecutableIdentity: String = "macho-uuid:cli"
) -> SwiftPMToolIdentityContext {
    SwiftPMToolIdentityContext(
        repoRoot: repoRoot,
        runningExecutableIdentity: runningExecutableIdentity,
        builds: [
            SwiftPMToolBuildRecipe(
                product: "privateheaderkit-raw-helper",
                configuration: "debug",
                destination: .host
            ),
        ],
        buildEnvironment: [:]
    )
}

private func identityRunner(description: String) async -> RecordingCommandRunner {
    let runner = RecordingCommandRunner()
    await runner.setCaptureOutput(
        description,
        for: ["swift", "package", "describe", "--type", "json"]
    )
    await runner.setCaptureOutput(
        #"{"targets":[{"name":"Helper","dependencies":[]},{"name":"Runtime","dependencies":[]}]}"#,
        for: ["swift", "package", "dump-package"]
    )
    await runner.setCaptureOutput("/usr/bin/swift", for: ["which", "swift"])
    await runner.setCaptureOutput("Swift test", for: ["swift", "--version"])
    await runner.setCaptureOutput("Xcode test", for: ["xcodebuild", "-version"])
    await runner.setCaptureOutput(
        #"{"compilerVersion":"Swift test","target":{"triple":"arm64-apple-macosx"}}"#,
        for: ["swift", "-print-target-info"]
    )
    await runner.setCaptureOutput(
        "TEST_MACOS_SDK",
        for: ["xcrun", "--sdk", "macosx", "--show-sdk-build-version"]
    )
    return runner
}

private func resolvedFixture(reversed: Bool) -> String {
    let first = """
    {"identity":"a","kind":"remoteSourceControl","location":"https://example.com/a","state":{"revision":"aaa","version":"1.0.0"}}
    """
    let second = """
    {"identity":"b","kind":"remoteSourceControl","location":"https://example.com/b","state":{"revision":"bbb","version":"2.0.0"}}
    """
    let pins = reversed ? [second, first] : [first, second]
    return "{\"pins\":[\(pins.joined(separator: ","))],\"version\":3}"
}

private func makeIdentityFixtureRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "PrivateHeaderKitToolIdentity-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func writeExecutable(_ contents: String, to url: URL) throws {
    try Data(contents.utf8).write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: UInt16(0o755))],
        ofItemAtPath: url.path
    )
}
