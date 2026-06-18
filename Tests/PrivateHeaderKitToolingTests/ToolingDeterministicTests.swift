import Foundation
import Testing
@testable import PrivateHeaderKitTooling
import PrivateHeaderKitTestSupport

@Suite
struct FileOpsDeterministicTests {
    @Test func buildStageDirUsesInjectedPidDateAndTimeZone() {
        let outDir = URL(fileURLWithPath: "/tmp/out", isDirectory: true)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let stageDir = FileOps.buildStageDir(
            outDir: outDir,
            pid: 42,
            date: date,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(stageDir.path == "/tmp/out/.tmp-42-20231114221320")
    }

    @Test func normalizeAndDenormalizeBundleDirsHandleConflictsDeterministically() throws {
        let dirs = try makeTemporaryTestDirectories()
        let parent = dirs.root.appendingPathComponent("Bundles", isDirectory: true)
        let bundle = parent.appendingPathComponent("Foo.bundle", isDirectory: true)
        let normalized = parent.appendingPathComponent("Foo", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: normalized, withIntermediateDirectories: true)
        try Data("bundle".utf8).write(to: bundle.appendingPathComponent("Bundle.h"))
        try Data("normalized".utf8).write(to: normalized.appendingPathComponent("Normalized.h"))

        let result = try FileOps.normalizeBundleDir(
            bundle,
            allowedExtensions: ["bundle"],
            overwrite: false,
            fileManager: .default
        )

        #expect(result.path == normalized.path)
        #expect(FileManager.default.fileExists(atPath: normalized.appendingPathComponent("Bundle.h").path))
        #expect(FileManager.default.fileExists(atPath: normalized.appendingPathComponent("Normalized.h").path))

        let denormalized = try FileOps.denormalizeBundleDir(
            normalized,
            bundleExtension: "bundle",
            overwrite: true,
            fileManager: .default
        )

        #expect(denormalized.lastPathComponent == "Foo.bundle")
        #expect(FileManager.default.fileExists(atPath: denormalized.appendingPathComponent("Bundle.h").path))
    }
}

@Suite
struct PathAndVersionTests {
    @Test func versionKeyParsesNumericComponents() {
        #expect(VersionUtils.versionKey("26.10.1") == [26, 10, 1])
        #expect(VersionUtils.versionKey("26.beta.3") == [26, 0, 3])
    }

    @Test func whichFindsExecutableFromInjectedPath() throws {
        let dirs = try makeTemporaryTestDirectories()
        let binDir = dirs.root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let executable = binDir.appendingPathComponent("tool", isDirectory: false)
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let found = Which.find("tool", environment: ["PATH": binDir.path])
        #expect(found?.path == executable.path)
        #expect(Which.find("missing", environment: ["PATH": binDir.path]) == nil)
    }
}

@Suite
struct SimctlDeterministicTests {
    @Test func listRuntimesParsesAvailableIOSRuntimesInVersionOrder() throws {
        let runner = RecordingCommandRunner()
        runner.setCaptureOutput(
            """
            {
              "runtimes": [
                {"name": "iOS 26.10", "version": "26.10", "identifier": "ios-26-10", "runtimeRoot": "/runtimes/26.10", "isAvailable": true, "buildversion": "23Z1"},
                {"name": "iOS 26.2", "version": "26.2", "identifier": "ios-26-2", "runtimeRoot": "/runtimes/26.2", "isAvailable": true, "buildversion": "23C54"},
                {"name": "iOS 25.0", "version": "25.0", "identifier": "ios-25-0", "runtimeRoot": "/runtimes/25.0", "isAvailable": false},
                {"name": "watchOS 26.0", "version": "26.0", "identifier": "watch-26-0", "runtimeRoot": "/runtimes/watch", "isAvailable": true}
              ]
            }
            """,
            for: ["xcrun", "simctl", "list", "runtimes", "-j"]
        )

        let runtimes = try Simctl.listRuntimes(runner: runner)

        #expect(runtimes.map(\.version) == ["26.2", "26.10"])
        #expect(runtimes.first?.build == "23C54")
        #expect(runner.captureCommands.map(\.command) == [["xcrun", "simctl", "list", "runtimes", "-j"]])
    }

    @Test func listDevicesParsesDevicesForRuntime() throws {
        let runner = RecordingCommandRunner()
        runner.setCaptureOutput(
            """
            {
              "devices": {
                "ios-26-2": [
                  {"name": "iPhone 17", "udid": "A", "state": "Shutdown"},
                  {"name": "iPhone 17 Pro", "udid": "B", "state": "Booted"}
                ],
                "other": [
                  {"name": "Other", "udid": "C", "state": "Shutdown"}
                ]
              }
            }
            """,
            for: ["xcrun", "simctl", "list", "devices", "-j"]
        )

        let devices = try Simctl.listDevices(runtimeId: "ios-26-2", runner: runner)

        #expect(devices.map(\.udid) == ["A", "B"])
        #expect(devices.map(\.state) == ["Shutdown", "Booted"])
    }

    @Test func ensureDeviceBootedSkipsBootedDeviceUnlessForced() throws {
        let runner = RecordingCommandRunner()
        var booted = DeviceInfo(name: "iPhone", udid: "BOOTED", state: "Booted")

        try Simctl.ensureDeviceBooted(&booted, runner: runner, force: false)
        #expect(runner.simpleCommands.isEmpty)

        try Simctl.ensureDeviceBooted(&booted, runner: runner, force: true)
        #expect(runner.simpleCommands.map(\.command) == [
            ["xcrun", "simctl", "boot", "BOOTED"],
            ["xcrun", "simctl", "bootstatus", "BOOTED", "-b"],
        ])
    }
}
