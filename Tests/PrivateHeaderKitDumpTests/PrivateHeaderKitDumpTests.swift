import Foundation
import Testing

@testable import PrivateHeaderKitDump
import PrivateHeaderKitTooling

private final class StubCommandRunner: CommandRunning {
    private var captureOutputs: [String: String] = [:]

    var capturedRunCaptureCommands: [[String]] = []
    var capturedRunSimpleCommands: [[String]] = []
    var capturedRunStreamingCommands: [[String]] = []

    func setCaptureOutput(_ output: String, for command: [String]) {
        captureOutputs[key(for: command)] = output
    }

    func runCapture(_ command: [String], env _: [String: String]?, cwd _: URL?) throws -> String {
        capturedRunCaptureCommands.append(command)
        guard let output = captureOutputs[key(for: command)] else {
            throw ToolingError.message("unexpected runCapture command: \(command.joined(separator: " "))")
        }
        return output
    }

    func runSimple(_ command: [String], env _: [String: String]?, cwd _: URL?) throws {
        capturedRunSimpleCommands.append(command)
    }

    func runStreaming(_ command: [String], env _: [String: String]?, cwd _: URL?) throws -> StreamingCommandResult {
        capturedRunStreamingCommands.append(command)
        return StreamingCommandResult(status: 0, wasKilled: false, lastLines: [])
    }

    private func key(for command: [String]) -> String {
        command.joined(separator: "\u{1f}")
    }
}

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

private func makeContext(outDir: URL, layout: String = "headers") -> Context {
    Context(
        platform: .ios,
        execMode: .host,
        headerdumpBin: URL(fileURLWithPath: "/usr/bin/true"),
        osVersionLabel: "26.3.1",
        systemRoot: "/tmp/runtime",
        runtimeId: nil,
        runtimeBuild: nil,
        macOSBuildVersion: nil,
        device: nil,
        outDir: outDir,
        stageDir: outDir.appendingPathComponent(".tmp-stage", isDirectory: true),
        skipExisting: true,
        useSharedCache: true,
        verbose: false,
        layout: layout,
        categories: ["Frameworks"],
        frameworkNames: [],
        frameworkFilters: []
    )
}

private func makeFakeHeaderdumpScript(
    at url: URL,
    invocationLog: URL,
    nestedFailureToggle: URL? = nil,
    failingNestedSuffix: String? = nil
) throws {
    let toggleCheck: String
    if let nestedFailureToggle, let failingNestedSuffix {
        toggleCheck = """
        if [[ -f "\(nestedFailureToggle.path)" && "$source_path" == *"\(failingNestedSuffix)" ]]; then
          print -u2 -- "simulated failure for $source_path"
          exit 1
        fi
        """
    } else {
        toggleCheck = ""
    }

    let script = """
    #!/bin/zsh
    set -euo pipefail

    stage_dir=""
    source_path=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -o)
          stage_dir="$2"
          shift 2
          ;;
        -r)
          source_path="$2"
          shift 2
          ;;
        -b|-h|-s|-R|-c|-D)
          shift
          ;;
        *)
          if [[ -z "$source_path" ]]; then
            source_path="$1"
          fi
          shift
          ;;
      esac
    done

    print -r -- "$source_path" >> "\(invocationLog.path)"
    \(toggleCheck)
    relative_path="${source_path#*/System/Library/}"
    output_dir="$stage_dir/System/Library/$relative_path/Headers"
    mkdir -p "$output_dir"
    print -r -- "// generated: $relative_path" > "$output_dir/Generated.h"
    """

    try script.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

private func invocationLines(at url: URL) throws -> [String] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n")
        .map(String.init)
}

@Suite struct PrivateHeaderKitDumpTests {
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
                #expect(Bool(false))
            } catch let error as ToolingError {
                guard case .invalidArgument = error else {
                    #expect(Bool(false))
                    continue
                }
            } catch {
                #expect(Bool(false))
            }
        }
    }

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
        let runner = StubCommandRunner()

        let picked = try Simctl.resolveDefaultDevice(runtime: runtime, devices: devices, runner: runner)
        #expect(picked.udid == "CLONE")
        #expect(runner.capturedRunCaptureCommands.isEmpty)
    }

    @Test func resolveDefaultDeviceSkipsCloneForBootedBaseDevice() throws {
        let runtime = try makeRuntimeInfo()
        let devices = [
            try makeDeviceInfo(name: "iPhone 17", udid: "BOOTED", state: "Booted")
        ]
        let runner = StubCommandRunner()

        let picked = try Simctl.resolveDefaultDevice(runtime: runtime, devices: devices, runner: runner)
        #expect(picked.udid == "BOOTED")
        #expect(runner.capturedRunCaptureCommands.isEmpty)
    }

    @Test func resolveDefaultDeviceClonesFromShutdownBaseDevice() throws {
        let runtime = try makeRuntimeInfo()
        let devices = [
            try makeDeviceInfo(name: "iPhone 17", udid: "SHUTDOWN", state: "Shutdown")
        ]
        let cloneName = Simctl.defaultCloneName(version: runtime.version)
        let runner = StubCommandRunner()
        runner.setCaptureOutput("CLONED-UDID\n", for: ["xcrun", "simctl", "clone", "SHUTDOWN", cloneName])

        let picked = try Simctl.resolveDefaultDevice(runtime: runtime, devices: devices, runner: runner)
        #expect(picked.name == cloneName)
        #expect(picked.udid == "CLONED-UDID")
        #expect(runner.capturedRunCaptureCommands.count == 1)
    }

    @Test func existingFrameworksRequireCompletionMarker() throws {
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let ctx = makeContext(outDir: outDir)

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

    @Test func writeCompletionMarkerCreatesExpectedMetadata() throws {
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        try writeCompletionMarker(
            in: outDir,
            imagePath: "usr/lib/libobjc.A.dylib",
            layout: "headers"
        )

        let data = try Data(contentsOf: completionMarkerURL(for: outDir))
        let marker = try JSONDecoder().decode(CompletionMarker.self, from: data)
        #expect(marker.tool == "privateheaderkit-dump")
        #expect(marker.imagePath == "usr/lib/libobjc.A.dylib")
        #expect(marker.layout == "headers")
        #expect(!marker.completedAt.isEmpty)
        #expect(hasCompletionMarker(in: outDir))
    }

    @Test func splitFrameworkRerunsMarkerlessPartialAndSkipsCompletedFramework() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let runtimeRoot = tempDir.appendingPathComponent("RuntimeRoot", isDirectory: true)
        let outDir = tempDir.appendingPathComponent("Out", isDirectory: true)
        let frameworkDir = runtimeRoot
            .appendingPathComponent("System/Library/Frameworks/Foo.framework", isDirectory: true)
        let invocationLog = tempDir.appendingPathComponent("invocations.log", isDirectory: false)
        let scriptURL = tempDir.appendingPathComponent("fake-headerdump.zsh", isDirectory: false)

        try FileManager.default.createDirectory(at: frameworkDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try makeFakeHeaderdumpScript(at: scriptURL, invocationLog: invocationLog)

        var ctx = makeContext(outDir: outDir)
        ctx.platform = .macos
        ctx.systemRoot = runtimeRoot.path
        ctx.headerdumpBin = scriptURL
        ctx.stageDir = tempDir.appendingPathComponent(".tmp-stage", isDirectory: true)
        ctx.categories = ["Frameworks"]
        ctx.skipExisting = true
        ctx.layout = "headers"

        let outputDir = frameworkOutputDir(ctx: ctx, category: "Frameworks", frameworkName: "Foo.framework")
        let staleHeader = outputDir.appendingPathComponent("Headers/PartialOnly.h", isDirectory: false)
        try FileManager.default.createDirectory(at: staleHeader.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: staleHeader)

        try FileOps.resetStageDir(ctx.stageDir)
        let hadFailures = try dumpCategorySplit(category: "Frameworks", ctx: ctx, runner: StubCommandRunner())
        #expect(hadFailures == false)
        #expect(FileManager.default.fileExists(atPath: outputDir.appendingPathComponent("Headers/Generated.h").path))
        #expect(!FileManager.default.fileExists(atPath: staleHeader.path))
        #expect(hasCompletionMarker(in: outputDir))
        #expect(try invocationLines(at: invocationLog).count == 1)

        try FileOps.resetStageDir(ctx.stageDir)
        let hadFailuresOnSecondRun = try dumpCategorySplit(category: "Frameworks", ctx: ctx, runner: StubCommandRunner())
        #expect(hadFailuresOnSecondRun == false)
        #expect(try invocationLines(at: invocationLog).count == 1)
    }

    @Test func splitFrameworkSkipsMarkerUntilNestedFailureIsRecovered() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let runtimeRoot = tempDir.appendingPathComponent("RuntimeRoot", isDirectory: true)
        let outDir = tempDir.appendingPathComponent("Out", isDirectory: true)
        let frameworkDir = runtimeRoot
            .appendingPathComponent("System/Library/Frameworks/Foo.framework/XPCServices/Bad.xpc", isDirectory: true)
        let invocationLog = tempDir.appendingPathComponent("invocations.log", isDirectory: false)
        let failureToggle = tempDir.appendingPathComponent("fail-nested", isDirectory: false)
        let scriptURL = tempDir.appendingPathComponent("fake-headerdump.zsh", isDirectory: false)

        try FileManager.default.createDirectory(at: frameworkDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try Data().write(to: failureToggle)
        try makeFakeHeaderdumpScript(
            at: scriptURL,
            invocationLog: invocationLog,
            nestedFailureToggle: failureToggle,
            failingNestedSuffix: "XPCServices/Bad.xpc"
        )

        var ctx = makeContext(outDir: outDir)
        ctx.platform = .macos
        ctx.systemRoot = runtimeRoot.path
        ctx.headerdumpBin = scriptURL
        ctx.stageDir = tempDir.appendingPathComponent(".tmp-stage", isDirectory: true)
        ctx.categories = ["Frameworks"]
        ctx.skipExisting = true
        ctx.layout = "headers"
        ctx.nestedEnabled = true

        let outputDir = frameworkOutputDir(ctx: ctx, category: "Frameworks", frameworkName: "Foo.framework")

        try FileOps.resetStageDir(ctx.stageDir)
        let firstHadFailures = try dumpCategorySplit(category: "Frameworks", ctx: ctx, runner: StubCommandRunner())
        #expect(firstHadFailures == true)
        #expect(!hasCompletionMarker(in: outputDir))
        let failuresPath = outDir.appendingPathComponent("_failures.txt", isDirectory: false)
        let failuresText = try String(contentsOf: failuresPath, encoding: .utf8)
        #expect(failuresText.contains("Frameworks/Foo.framework/XPCServices/Bad.xpc"))
        #expect(try invocationLines(at: invocationLog).count == 2)

        try FileManager.default.removeItem(at: failureToggle)
        try FileOps.resetStageDir(ctx.stageDir)
        let secondHadFailures = try dumpCategorySplit(category: "Frameworks", ctx: ctx, runner: StubCommandRunner())
        #expect(secondHadFailures == false)
        #expect(hasCompletionMarker(in: outputDir))
        #expect(FileManager.default.fileExists(atPath: outputDir.appendingPathComponent("Headers/Generated.h").path))
        #expect(try invocationLines(at: invocationLog).count == 4)
    }

    @Test func systemLibraryBundleLayoutRemovesStaleHeadersLayoutDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let runtimeRoot = tempDir.appendingPathComponent("RuntimeRoot", isDirectory: true)
        let outDir = tempDir.appendingPathComponent("Out", isDirectory: true)
        let bundleDir = runtimeRoot
            .appendingPathComponent("System/Library/PreferenceBundles/Foo.bundle", isDirectory: true)
        let invocationLog = tempDir.appendingPathComponent("invocations.log", isDirectory: false)
        let scriptURL = tempDir.appendingPathComponent("fake-headerdump.zsh", isDirectory: false)

        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try makeFakeHeaderdumpScript(at: scriptURL, invocationLog: invocationLog)

        var ctx = makeContext(outDir: outDir, layout: "bundle")
        ctx.platform = .macos
        ctx.systemRoot = runtimeRoot.path
        ctx.headerdumpBin = scriptURL
        ctx.stageDir = tempDir.appendingPathComponent(".tmp-stage", isDirectory: true)
        ctx.skipExisting = false

        let staleHeadersLayoutDir = outDir
            .appendingPathComponent("SystemLibrary/PreferenceBundles/Foo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: staleHeadersLayoutDir.appendingPathComponent("Headers", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("stale".utf8).write(to: staleHeadersLayoutDir.appendingPathComponent("Headers/Old.h"))
        try writeCompletionMarker(
            in: staleHeadersLayoutDir,
            imagePath: "SystemLibrary/PreferenceBundles/Foo.bundle",
            layout: "headers"
        )

        try FileOps.resetStageDir(ctx.stageDir)
        let hadFailures = try dumpSystemLibraryItems(
            ctx: ctx,
            items: ["PreferenceBundles/Foo.bundle"],
            runner: StubCommandRunner()
        )

        let bundleOutputDir = systemLibraryOutputDir(ctx: ctx, relativePath: "PreferenceBundles/Foo.bundle")
        #expect(hadFailures == false)
        #expect(!FileManager.default.fileExists(atPath: staleHeadersLayoutDir.path))
        #expect(FileManager.default.fileExists(atPath: bundleOutputDir.appendingPathComponent("Headers/Generated.h").path))
        #expect(hasCompletionMarker(in: bundleOutputDir))
        #expect(try invocationLines(at: invocationLog).count == 1)
    }

    @Test func splitFrameworkSkipsCompletedAlternateLayoutWithoutRedump() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let runtimeRoot = tempDir.appendingPathComponent("RuntimeRoot", isDirectory: true)
        let outDir = tempDir.appendingPathComponent("Out", isDirectory: true)
        let frameworkDir = runtimeRoot
            .appendingPathComponent("System/Library/Frameworks/Foo.framework", isDirectory: true)
        let invocationLog = tempDir.appendingPathComponent("invocations.log", isDirectory: false)
        let scriptURL = tempDir.appendingPathComponent("fake-headerdump.zsh", isDirectory: false)

        try FileManager.default.createDirectory(at: frameworkDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try makeFakeHeaderdumpScript(at: scriptURL, invocationLog: invocationLog)

        var ctx = makeContext(outDir: outDir, layout: "headers")
        ctx.platform = .macos
        ctx.systemRoot = runtimeRoot.path
        ctx.headerdumpBin = scriptURL
        ctx.stageDir = tempDir.appendingPathComponent(".tmp-stage", isDirectory: true)
        ctx.categories = ["Frameworks"]
        ctx.skipExisting = true

        let alternateLayoutDir = outDir
            .appendingPathComponent("Frameworks/Foo.framework", isDirectory: true)
        let normalizedDir = frameworkOutputDir(ctx: ctx, category: "Frameworks", frameworkName: "Foo.framework")
        try FileManager.default.createDirectory(
            at: alternateLayoutDir.appendingPathComponent("Headers", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: normalizedDir.appendingPathComponent("Headers", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("ok".utf8).write(to: alternateLayoutDir.appendingPathComponent("Headers/Generated.h"))
        try Data("stale".utf8).write(to: normalizedDir.appendingPathComponent("Headers/Stale.h"))
        try writeCompletionMarker(
            in: alternateLayoutDir,
            imagePath: "Frameworks/Foo.framework",
            layout: "bundle"
        )

        try FileOps.resetStageDir(ctx.stageDir)
        let hadFailures = try dumpCategorySplit(category: "Frameworks", ctx: ctx, runner: StubCommandRunner())

        #expect(hadFailures == false)
        #expect(FileManager.default.fileExists(atPath: normalizedDir.appendingPathComponent("Headers/Generated.h").path))
        #expect(!FileManager.default.fileExists(atPath: normalizedDir.appendingPathComponent("Headers/Stale.h").path))
        #expect(hasCompletionMarker(in: normalizedDir))
        #expect(try invocationLines(at: invocationLog).isEmpty)
    }

    @Test func systemLibrarySkipsCompletedAlternateLayoutWithoutRedump() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let runtimeRoot = tempDir.appendingPathComponent("RuntimeRoot", isDirectory: true)
        let outDir = tempDir.appendingPathComponent("Out", isDirectory: true)
        let bundleDir = runtimeRoot
            .appendingPathComponent("System/Library/PreferenceBundles/Foo.bundle", isDirectory: true)
        let invocationLog = tempDir.appendingPathComponent("invocations.log", isDirectory: false)
        let scriptURL = tempDir.appendingPathComponent("fake-headerdump.zsh", isDirectory: false)

        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try makeFakeHeaderdumpScript(at: scriptURL, invocationLog: invocationLog)

        var ctx = makeContext(outDir: outDir, layout: "headers")
        ctx.platform = .macos
        ctx.systemRoot = runtimeRoot.path
        ctx.headerdumpBin = scriptURL
        ctx.stageDir = tempDir.appendingPathComponent(".tmp-stage", isDirectory: true)
        ctx.skipExisting = true

        let alternateLayoutDir = outDir
            .appendingPathComponent("SystemLibrary/PreferenceBundles/Foo.bundle", isDirectory: true)
        let normalizedDir = systemLibraryOutputDir(ctx: ctx, relativePath: "PreferenceBundles/Foo.bundle")
        try FileManager.default.createDirectory(
            at: alternateLayoutDir.appendingPathComponent("Headers", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: normalizedDir.appendingPathComponent("Headers", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("ok".utf8).write(to: alternateLayoutDir.appendingPathComponent("Headers/Generated.h"))
        try Data("stale".utf8).write(to: normalizedDir.appendingPathComponent("Headers/Stale.h"))
        try writeCompletionMarker(
            in: alternateLayoutDir,
            imagePath: "SystemLibrary/PreferenceBundles/Foo.bundle",
            layout: "bundle"
        )

        try FileOps.resetStageDir(ctx.stageDir)
        let hadFailures = try dumpSystemLibraryItems(
            ctx: ctx,
            items: ["PreferenceBundles/Foo.bundle"],
            runner: StubCommandRunner()
        )

        #expect(hadFailures == false)
        #expect(FileManager.default.fileExists(atPath: normalizedDir.appendingPathComponent("Headers/Generated.h").path))
        #expect(!FileManager.default.fileExists(atPath: normalizedDir.appendingPathComponent("Headers/Stale.h").path))
        #expect(hasCompletionMarker(in: normalizedDir))
        #expect(try invocationLines(at: invocationLog).isEmpty)
    }
}
