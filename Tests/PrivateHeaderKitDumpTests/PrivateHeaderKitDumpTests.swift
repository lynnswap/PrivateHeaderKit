import Foundation
import Testing

@testable import PrivateHeaderKitDump
import PrivateHeaderKitTooling
import PrivateHeaderKitTestSupport

private func makeRuntimeInfo(
    version: String = "26.2",
    build: String = "23C54",
    identifier: String = "com.apple.CoreSimulator.SimRuntime.iOS-26-2",
    runtimeRoot: String = "/tmp/runtime"
) throws -> RuntimeInfo {
    let payload = """
    {
      "version": "\(version)",
      "build": "\(build)",
      "identifier": "\(identifier)",
      "runtimeRoot": "\(runtimeRoot)"
    }
    """
    return try JSONDecoder().decode(RuntimeInfo.self, from: Data(payload.utf8))
}

private func makeDeviceInfo(name: String, udid: String, state: String) throws -> DeviceInfo {
    let payload = """
    {
      "name": "\(name)",
      "udid": "\(udid)",
      "state": "\(state)"
    }
    """
    return try JSONDecoder().decode(DeviceInfo.self, from: Data(payload.utf8))
}

private func makeContext(
    dirs: TestDirectories,
    layout: String = "headers",
    platform: TargetPlatform = .macos,
    execMode: ExecMode = .host
) throws -> Context {
    Context(
        platform: platform,
        execMode: execMode,
        headerdumpBin: URL(fileURLWithPath: "/test/headerdump"),
        osVersionLabel: "26.3.1",
        systemRoot: dirs.runtimeRoot.path,
        runtimeId: platform == .ios ? "com.apple.CoreSimulator.SimRuntime.iOS-26-2" : nil,
        runtimeBuild: nil,
        macOSBuildVersion: platform == .macos ? "23C54" : nil,
        device: execMode == .simulator ? try makeDeviceInfo(name: "iPhone 17", udid: "SIM-UDID", state: "Booted") : nil,
        outDir: dirs.outDir,
        stageDir: dirs.stageDir,
        skipExisting: true,
        useSharedCache: true,
        verbose: false,
        layout: layout,
        categories: ["Frameworks"],
        frameworkNames: [],
        frameworkFilters: []
    )
}

@Suite
struct DumpSelectionTests {
    @Test func targetFrameworkOnlySelectsFrameworks() throws {
        var args = DumpArguments()
        args.targets = ["SafariShared"]

        let selection = try buildDumpSelection(args)
        #expect(selection.categories == ["Frameworks", "PrivateFrameworks"])
        #expect(selection.frameworkNames.contains("safarishared.framework"))
        #expect(selection.dumpAllSystemLibraryExtras == false)
        #expect(selection.systemLibraryItems.isEmpty)
        #expect(selection.dumpAllUsrLibDylibs == false)
        #expect(selection.usrLibDylibs.isEmpty)
        #expect(selection.dumpAllFrameworks == false)
        #expect(resolveNestedEnabled(args) == true)
    }

    @Test func targetSystemItemOnlyDoesNotDumpFrameworks() throws {
        var args = DumpArguments()
        args.targets = ["PreferenceBundles/Foo.bundle"]

        let selection = try buildDumpSelection(args)
        #expect(selection.categories.isEmpty)
        #expect(selection.dumpAllSystemLibraryExtras == false)
        #expect(selection.systemLibraryItems == ["PreferenceBundles/Foo.bundle"])
        #expect(selection.dumpAllUsrLibDylibs == false)
        #expect(selection.usrLibDylibs.isEmpty)
    }

    @Test func targetAllPresetEnablesAllScopes() throws {
        var args = DumpArguments()
        args.targets = ["@all"]

        let selection = try buildDumpSelection(args)
        #expect(selection.categories == ["Frameworks", "PrivateFrameworks"])
        #expect(selection.dumpAllSystemLibraryExtras == true)
        #expect(selection.dumpAllUsrLibDylibs == true)
        #expect(selection.dumpAllFrameworks == true)
        #expect(selection.frameworkNames.isEmpty)
    }

    @Test func noNestedDisablesNested() {
        var args = DumpArguments()
        args.targets = ["SafariShared"]
        args.nested = false
        #expect(resolveNestedEnabled(args) == false)
    }

    @Test func legacyScopeAllEqualsAllPreset() throws {
        var args = DumpArguments()
        args.scope = .all

        let selection = try buildDumpSelection(args)
        #expect(selection.categories == ["Frameworks", "PrivateFrameworks"])
        #expect(selection.dumpAllSystemLibraryExtras == true)
        #expect(selection.dumpAllUsrLibDylibs == true)
    }

    @Test func targetUsrLibDylibParsesName() throws {
        var args = DumpArguments()
        args.targets = ["/usr/lib/libobjc.A.dylib"]

        let selection = try buildDumpSelection(args)
        #expect(selection.categories.isEmpty)
        #expect(selection.dumpAllUsrLibDylibs == false)
        #expect(selection.usrLibDylibs == ["libobjc.A.dylib"])
    }

    @Test func systemLibraryTargetRejectsDotDotComponents() {
        let targets = [
            "../Foo.bundle",
            "PreferenceBundles/../Foo.bundle",
            "./Foo.bundle",
            "PreferenceBundles/./Foo.bundle",
        ]
        for target in targets {
            var args = DumpArguments()
            args.targets = [target]
            do {
                _ = try buildDumpSelection(args)
                Issue.record("expected invalidArgument for \(target)")
            } catch let error as ToolingError {
                guard case .invalidArgument = error else {
                    Issue.record("unexpected error: \(error)")
                    continue
                }
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }
    }
}

@Suite
struct DumpFallbackTests {
    @Test func launchFailureFromSimctlFallsBackToHost() {
        let error = ToolingError.processLaunchFailed(
            command: ["xcrun", "simctl", "spawn", "UDID", "/tmp/headerdump-sim"],
            underlying: "No such file or directory"
        )

        #expect(shouldFallbackToHost(error) == true)
    }

    @Test func launchFailureDoesNotFallbackWhenRuntimeIsMissing() {
        let error = ToolingError.processLaunchFailed(
            command: ["xcrun", "simctl", "spawn", "UDID", "/tmp/headerdump-sim"],
            underlying: "iOS runtime not found or unavailable"
        )

        #expect(shouldFallbackToHost(error) == false)
    }
}

@Suite
struct DumpCompletionMarkerTests {
    @Test func existingFrameworksRequireCompletionMarkerAndHeaderArtifact() throws {
        let dirs = try makeTemporaryTestDirectories()
        let ctx = try makeContext(dirs: dirs)

        let completeDir = frameworkOutputDir(ctx: ctx, category: "Frameworks", frameworkName: "Complete.framework")
        let partialDir = frameworkOutputDir(ctx: ctx, category: "Frameworks", frameworkName: "Partial.framework")
        let markerOnlyDir = frameworkOutputDir(ctx: ctx, category: "Frameworks", frameworkName: "MarkerOnly.framework")
        try FileManager.default.createDirectory(at: completeDir.appendingPathComponent("Headers", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: partialDir.appendingPathComponent("Headers", isDirectory: true), withIntermediateDirectories: true)
        try Data("ok".utf8).write(to: completeDir.appendingPathComponent("Headers/Complete.h"))
        try Data("ok".utf8).write(to: partialDir.appendingPathComponent("Headers/Partial.h"))
        try FileManager.default.createDirectory(at: markerOnlyDir, withIntermediateDirectories: true)
        try writeCompletionMarker(in: completeDir, imagePath: "Frameworks/Complete.framework", layout: ctx.layout)
        try writeCompletionMarker(in: markerOnlyDir, imagePath: "Frameworks/MarkerOnly.framework", layout: ctx.layout)

        let existing = existingFrameworksInCategory(
            ctx: ctx,
            category: "Frameworks",
            frameworks: Set(["complete.framework", "partial.framework", "markeronly.framework"])
        )
        #expect(existing == Set(["complete.framework"]))
    }

    @Test func writeCompletionMarkerCreatesExpectedMetadataWithInjectedDate() throws {
        let dirs = try makeTemporaryTestDirectories()
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

        try writeCompletionMarker(
            in: dirs.outDir,
            imagePath: "usr/lib/libobjc.A.dylib",
            layout: "headers",
            date: fixedDate
        )

        let data = try Data(contentsOf: completionMarkerURL(for: dirs.outDir))
        let marker = try JSONDecoder().decode(CompletionMarker.self, from: data)
        #expect(marker.tool == "privateheaderkit-dump")
        #expect(marker.imagePath == "usr/lib/libobjc.A.dylib")
        #expect(marker.layout == "headers")
        #expect(marker.completedAt == "2023-11-14T22:13:20Z")
        #expect(hasCompletionMarker(in: dirs.outDir))
    }
}

@Suite
struct DumpFrameworkOrchestrationTests {
    @Test func splitFrameworkRerunsMarkerlessPartialAndSkipsCompletedFramework() throws {
        let dirs = try makeTemporaryTestDirectories()
        _ = try dirs.createFramework("Foo.framework")

        let headerdump = HeaderdumpFixtureRunner()
        let runner = RecordingCommandRunner()
        runner.streamingHandler = headerdump.handle(command:env:cwd:)

        var ctx = try makeContext(dirs: dirs, layout: "headers")
        ctx.skipExisting = true

        let outputDir = frameworkOutputDir(ctx: ctx, category: "Frameworks", frameworkName: "Foo.framework")
        let staleHeader = outputDir.appendingPathComponent("Headers/PartialOnly.h", isDirectory: false)
        try FileManager.default.createDirectory(at: staleHeader.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: staleHeader)

        try FileOps.resetStageDir(ctx.stageDir)
        let hadFailures = try dumpCategorySplit(category: "Frameworks", ctx: ctx, runner: runner)
        #expect(hadFailures == false)
        #expect(FileManager.default.fileExists(atPath: outputDir.appendingPathComponent("Headers/Generated.h").path))
        #expect(!FileManager.default.fileExists(atPath: staleHeader.path))
        #expect(hasCompletionMarker(in: outputDir))
        #expect(headerdump.sourcePaths.count == 1)

        let firstCommand = try #require(runner.streamingCommands.first)
        #expect(firstCommand.command.contains("-R"))
        #expect(firstCommand.command.contains("-c"))
        #expect(firstCommand.env == nil)

        try FileOps.resetStageDir(ctx.stageDir)
        let hadFailuresOnSecondRun = try dumpCategorySplit(category: "Frameworks", ctx: ctx, runner: runner)
        #expect(hadFailuresOnSecondRun == false)
        #expect(headerdump.sourcePaths.count == 1)
    }

    @Test func splitFrameworkSkipsMarkerUntilNestedFailureIsRecovered() throws {
        let dirs = try makeTemporaryTestDirectories()
        _ = try dirs.createFramework("Foo.framework")
            .appendingPathComponent("XPCServices/Bad.xpc", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dirs.runtimeRoot.appendingPathComponent("System/Library/Frameworks/Foo.framework/XPCServices/Bad.xpc", isDirectory: true),
            withIntermediateDirectories: true
        )

        let headerdump = HeaderdumpFixtureRunner(failingSourceSuffixes: ["XPCServices/Bad.xpc"])
        let runner = RecordingCommandRunner()
        runner.streamingHandler = headerdump.handle(command:env:cwd:)

        var ctx = try makeContext(dirs: dirs, layout: "headers")
        ctx.nestedEnabled = true

        let outputDir = frameworkOutputDir(ctx: ctx, category: "Frameworks", frameworkName: "Foo.framework")

        try FileOps.resetStageDir(ctx.stageDir)
        let firstHadFailures = try dumpCategorySplit(category: "Frameworks", ctx: ctx, runner: runner)
        #expect(firstHadFailures == true)
        #expect(!hasCompletionMarker(in: outputDir))
        let failuresText = try String(contentsOf: dirs.outDir.appendingPathComponent("_failures.txt"), encoding: .utf8)
        #expect(failuresText.contains("Frameworks/Foo.framework/XPCServices/Bad.xpc"))
        #expect(headerdump.sourcePaths.count == 2)

        headerdump.failingSourceSuffixes = []
        try FileOps.resetStageDir(ctx.stageDir)
        let secondHadFailures = try dumpCategorySplit(category: "Frameworks", ctx: ctx, runner: runner)
        #expect(secondHadFailures == false)
        #expect(hasCompletionMarker(in: outputDir))
        #expect(FileManager.default.fileExists(atPath: outputDir.appendingPathComponent("Headers/Generated.h").path))
        #expect(headerdump.sourcePaths.count == 4)
    }

    @Test func splitFrameworkSkipsCompletedAlternateLayoutWithoutRedump() throws {
        let dirs = try makeTemporaryTestDirectories()
        _ = try dirs.createFramework("Foo.framework")

        let headerdump = HeaderdumpFixtureRunner()
        let runner = RecordingCommandRunner()
        runner.streamingHandler = headerdump.handle(command:env:cwd:)

        var ctx = try makeContext(dirs: dirs, layout: "headers")
        ctx.skipExisting = true

        let alternateLayoutDir = dirs.outDir.appendingPathComponent("Frameworks/Foo.framework", isDirectory: true)
        let normalizedDir = frameworkOutputDir(ctx: ctx, category: "Frameworks", frameworkName: "Foo.framework")
        try FileManager.default.createDirectory(at: alternateLayoutDir.appendingPathComponent("Headers", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: normalizedDir.appendingPathComponent("Headers", isDirectory: true), withIntermediateDirectories: true)
        try Data("ok".utf8).write(to: alternateLayoutDir.appendingPathComponent("Headers/Generated.h"))
        try Data("stale".utf8).write(to: normalizedDir.appendingPathComponent("Headers/Stale.h"))
        try writeCompletionMarker(in: alternateLayoutDir, imagePath: "Frameworks/Foo.framework", layout: "bundle")

        try FileOps.resetStageDir(ctx.stageDir)
        let hadFailures = try dumpCategorySplit(category: "Frameworks", ctx: ctx, runner: runner)

        #expect(hadFailures == false)
        #expect(FileManager.default.fileExists(atPath: normalizedDir.appendingPathComponent("Headers/Generated.h").path))
        #expect(!FileManager.default.fileExists(atPath: normalizedDir.appendingPathComponent("Headers/Stale.h").path))
        #expect(hasCompletionMarker(in: normalizedDir))
        #expect(headerdump.sourcePaths.isEmpty)
    }
}

@Suite
struct DumpSystemLibraryOrchestrationTests {
    @Test func systemLibraryBundleLayoutRemovesStaleHeadersLayoutDirectory() throws {
        let dirs = try makeTemporaryTestDirectories()
        _ = try dirs.createSystemLibraryBundle("PreferenceBundles/Foo.bundle")

        let headerdump = HeaderdumpFixtureRunner()
        let runner = RecordingCommandRunner()
        runner.streamingHandler = headerdump.handle(command:env:cwd:)

        var ctx = try makeContext(dirs: dirs, layout: "bundle")
        ctx.skipExisting = false

        let staleHeadersLayoutDir = dirs.outDir.appendingPathComponent("SystemLibrary/PreferenceBundles/Foo", isDirectory: true)
        try FileManager.default.createDirectory(at: staleHeadersLayoutDir.appendingPathComponent("Headers", isDirectory: true), withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: staleHeadersLayoutDir.appendingPathComponent("Headers/Old.h"))
        try writeCompletionMarker(in: staleHeadersLayoutDir, imagePath: "SystemLibrary/PreferenceBundles/Foo.bundle", layout: "headers")

        try FileOps.resetStageDir(ctx.stageDir)
        let hadFailures = try dumpSystemLibraryItems(
            ctx: ctx,
            items: ["PreferenceBundles/Foo.bundle"],
            runner: runner
        )

        let bundleOutputDir = systemLibraryOutputDir(ctx: ctx, relativePath: "PreferenceBundles/Foo.bundle")
        #expect(hadFailures == false)
        #expect(!FileManager.default.fileExists(atPath: staleHeadersLayoutDir.path))
        #expect(FileManager.default.fileExists(atPath: bundleOutputDir.appendingPathComponent("Headers/Generated.h").path))
        #expect(hasCompletionMarker(in: bundleOutputDir))
        #expect(headerdump.sourcePaths.count == 1)
    }

    @Test func systemLibrarySkipsCompletedAlternateLayoutWithoutRedump() throws {
        let dirs = try makeTemporaryTestDirectories()
        _ = try dirs.createSystemLibraryBundle("PreferenceBundles/Foo.bundle")

        let headerdump = HeaderdumpFixtureRunner()
        let runner = RecordingCommandRunner()
        runner.streamingHandler = headerdump.handle(command:env:cwd:)

        var ctx = try makeContext(dirs: dirs, layout: "headers")
        ctx.skipExisting = true

        let alternateLayoutDir = dirs.outDir.appendingPathComponent("SystemLibrary/PreferenceBundles/Foo.bundle", isDirectory: true)
        let normalizedDir = systemLibraryOutputDir(ctx: ctx, relativePath: "PreferenceBundles/Foo.bundle")
        try FileManager.default.createDirectory(at: alternateLayoutDir.appendingPathComponent("Headers", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: normalizedDir.appendingPathComponent("Headers", isDirectory: true), withIntermediateDirectories: true)
        try Data("ok".utf8).write(to: alternateLayoutDir.appendingPathComponent("Headers/Generated.h"))
        try Data("stale".utf8).write(to: normalizedDir.appendingPathComponent("Headers/Stale.h"))
        try writeCompletionMarker(in: alternateLayoutDir, imagePath: "SystemLibrary/PreferenceBundles/Foo.bundle", layout: "bundle")

        try FileOps.resetStageDir(ctx.stageDir)
        let hadFailures = try dumpSystemLibraryItems(
            ctx: ctx,
            items: ["PreferenceBundles/Foo.bundle"],
            runner: runner
        )

        #expect(hadFailures == false)
        #expect(FileManager.default.fileExists(atPath: normalizedDir.appendingPathComponent("Headers/Generated.h").path))
        #expect(!FileManager.default.fileExists(atPath: normalizedDir.appendingPathComponent("Headers/Stale.h").path))
        #expect(hasCompletionMarker(in: normalizedDir))
        #expect(headerdump.sourcePaths.isEmpty)
    }

    @Test func simulatorCommandUsesSimctlAndChildEnvironment() throws {
        let dirs = try makeTemporaryTestDirectories()
        let headerdump = HeaderdumpFixtureRunner()
        let runner = RecordingCommandRunner()
        runner.streamingHandler = headerdump.handle(command:env:cwd:)

        var ctx = try makeContext(dirs: dirs, layout: "headers", platform: .ios, execMode: .simulator)
        ctx.skipExisting = false

        try FileOps.resetStageDir(ctx.stageDir)
        let hadFailures = try dumpSystemLibraryItems(
            ctx: ctx,
            items: ["PreferenceBundles/Foo.bundle"],
            runner: runner
        )

        let command = try #require(runner.streamingCommands.first)
        #expect(hadFailures == false)
        #expect(Array(command.command.prefix(4)) == ["xcrun", "simctl", "spawn", "SIM-UDID"])
        #expect(command.command.contains("/System/Library/PreferenceBundles/Foo.bundle"))
        #expect(command.env?["SIMCTL_CHILD_PH_RUNTIME_ROOT"] == dirs.runtimeRoot.path)
        #expect(command.env?["SIMCTL_CHILD_DYLD_ROOT_PATH"] == dirs.runtimeRoot.path)
    }
}

@Suite
struct DumpSimctlDeviceSelectionTests {
    @Test func pickDefaultDevicePrefersShutdownDevice() throws {
        let devices = [
            try makeDeviceInfo(name: "iPhone 17", udid: "BOOTED", state: "Booted"),
            try makeDeviceInfo(name: "iPhone 17", udid: "SHUTDOWN", state: "Shutdown"),
        ]

        let picked = try Simctl.pickDefaultDevice(devices: devices)
        #expect(picked.udid == "SHUTDOWN")
    }

    @Test func pickDefaultDevicePrefersBootedOverTransientStates() throws {
        let devices = [
            try makeDeviceInfo(name: "iPhone 17", udid: "TRANSIENT", state: "Booting"),
            try makeDeviceInfo(name: "iPhone 17", udid: "BOOTED", state: "Booted"),
        ]

        let picked = try Simctl.pickDefaultDevice(devices: devices)
        #expect(picked.udid == "BOOTED")
    }

    @Test func resolveDefaultDeviceReusesExistingClone() throws {
        let runtime = try makeRuntimeInfo()
        let cloneName = Simctl.defaultCloneName(version: runtime.version)
        let devices = [
            try makeDeviceInfo(name: "iPhone 17", udid: "BOOTED", state: "Booted"),
            try makeDeviceInfo(name: cloneName, udid: "CLONE", state: "Shutdown"),
        ]
        let runner = RecordingCommandRunner()

        let picked = try Simctl.resolveDefaultDevice(runtime: runtime, devices: devices, runner: runner)
        #expect(picked.udid == "CLONE")
        #expect(runner.captureCommands.isEmpty)
    }

    @Test func resolveDefaultDeviceSkipsCloneForBootedBaseDevice() throws {
        let runtime = try makeRuntimeInfo()
        let devices = [
            try makeDeviceInfo(name: "iPhone 17", udid: "BOOTED", state: "Booted")
        ]
        let runner = RecordingCommandRunner()

        let picked = try Simctl.resolveDefaultDevice(runtime: runtime, devices: devices, runner: runner)
        #expect(picked.udid == "BOOTED")
        #expect(runner.captureCommands.isEmpty)
    }

    @Test func resolveDefaultDeviceClonesFromShutdownBaseDevice() throws {
        let runtime = try makeRuntimeInfo()
        let devices = [
            try makeDeviceInfo(name: "iPhone 17", udid: "SHUTDOWN", state: "Shutdown")
        ]
        let cloneName = Simctl.defaultCloneName(version: runtime.version)
        let runner = RecordingCommandRunner()
        runner.setCaptureOutput("CLONED-UDID\n", for: ["xcrun", "simctl", "clone", "SHUTDOWN", cloneName])

        let picked = try Simctl.resolveDefaultDevice(runtime: runtime, devices: devices, runner: runner)
        #expect(picked.name == cloneName)
        #expect(picked.udid == "CLONED-UDID")
        #expect(runner.captureCommands.count == 1)
    }
}
