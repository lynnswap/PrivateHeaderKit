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
}
