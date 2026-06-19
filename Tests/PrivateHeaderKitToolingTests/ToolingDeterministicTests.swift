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
                {
                  "name": "iOS 26.10",
                  "version": "26.10",
                  "identifier": "ios-26-10",
                  "runtimeRoot": "/runtimes/26.10",
                  "isAvailable": true,
                  "buildversion": "23Z1",
                  "supportedDeviceTypes": [
                    {"name":"iPhone 17","identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17","productFamily":"iPhone"}
                  ]
                },
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
        #expect(runtimes.last?.supportedDeviceTypes.first?.identifier == "com.apple.CoreSimulator.SimDeviceType.iPhone-17")
        #expect(runner.captureCommands.map(\.command) == [["xcrun", "simctl", "list", "runtimes", "-j"]])
    }

    @Test func findRuntimeMatchesExplicitBuildWhenProvided() throws {
        let runner = RecordingCommandRunner()
        runner.setCaptureOutput(
            """
            {
              "runtimes": [
                {"name": "iOS 27.0", "version": "27.0", "identifier": "ios-27-a", "runtimeRoot": "/runtimes/27A", "isAvailable": true, "buildversion": "24A1"},
                {"name": "iOS 27.0", "version": "27.0", "identifier": "ios-27-b", "runtimeRoot": "/runtimes/27B", "isAvailable": true, "buildversion": "24B2"}
              ]
            }
            """,
            for: ["xcrun", "simctl", "list", "runtimes", "-j"]
        )

        let runtime = try Simctl.findRuntime(version: "27.0", build: "24B2", runner: runner)

        #expect(runtime.identifier == "ios-27-b")
        #expect(runtime.runtimeRoot == "/runtimes/27B")
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

    @Test func resolveDeviceCreatesRelistsClonesAndBootsWhenRuntimeHasNoDevices() throws {
        let runner = RecordingCommandRunner()
        let runtime = RuntimeInfo(
            version: "27.0",
            build: "24A5355q",
            identifier: "ios-27",
            runtimeRoot: "/runtimes/27",
            supportedDeviceTypes: [
                DeviceTypeInfo(
                    name: "iPad Pro",
                    identifier: "com.apple.CoreSimulator.SimDeviceType.iPad-Pro",
                    productFamily: "iPad"
                ),
                DeviceTypeInfo(
                    name: "iPhone 17",
                    identifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
                    productFamily: "iPhone"
                ),
            ]
        )
        runner.setCaptureOutputs(
            [
                """
                {"devices":{"ios-27":[]}}
                """,
                """
                {"devices":{"ios-27":[{"name":"iPhone 17 (27.0)","udid":"BASE-001","state":"Shutdown"}]}}
                """,
            ],
            for: ["xcrun", "simctl", "list", "devices", "-j"]
        )
        runner.setCaptureOutput(
            "CLONE-001\n",
            for: ["xcrun", "simctl", "clone", "BASE-001", "Dumping Device (iOS 27.0)"]
        )

        let device = try Simctl.resolveDevice(runtime: runtime, query: nil, runner: runner, environment: [:])

        #expect(device.name == "Dumping Device (iOS 27.0)")
        #expect(device.udid == "CLONE-001")
        #expect(device.state == "Booted")
        #expect(runner.simpleCommands.map(\.command) == [
            [
                "xcrun",
                "simctl",
                "create",
                "iPhone 17 (27.0)",
                "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
                "ios-27",
            ],
            ["xcrun", "simctl", "boot", "CLONE-001"],
            ["xcrun", "simctl", "bootstatus", "CLONE-001", "-b"],
        ])
        #expect(!runner.captureCommands.map(\.command).contains(["xcrun", "simctl", "list", "devicetypes", "-j"]))
    }

    @Test func createDefaultDeviceFallsBackToRuntimeCompatibleDeviceTypes() throws {
        let runner = RecordingCommandRunner()
        let runtime = RuntimeInfo(
            version: "27.0",
            build: "24A5355q",
            identifier: "ios-27",
            runtimeRoot: "/runtimes/27"
        )
        runner.setCaptureOutput(
            """
            {
              "devicetypes": [
                {
                  "name": "iPhone 14",
                  "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-14",
                  "productFamily": "iPhone",
                  "minRuntimeVersionString": "16.0",
                  "maxRuntimeVersionString": "26.4"
                },
                {
                  "name": "iPhone 17",
                  "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
                  "productFamily": "iPhone",
                  "minRuntimeVersionString": "27.0",
                  "maxRuntimeVersionString": "28.0"
                },
                {
                  "name": "iPad Pro",
                  "identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro",
                  "productFamily": "iPad",
                  "minRuntimeVersionString": "27.0",
                  "maxRuntimeVersionString": "28.0"
                }
              ]
            }
            """,
            for: ["xcrun", "simctl", "list", "devicetypes", "-j"]
        )

        try Simctl.createDefaultDevice(runtime: runtime, runner: runner, environment: [:])

        #expect(runner.simpleCommands.map(\.command) == [
            [
                "xcrun",
                "simctl",
                "create",
                "iPhone 17 (27.0)",
                "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
                "ios-27",
            ],
        ])
    }

    @Test func createDefaultDeviceFallsBackToNumericRuntimeCompatibleDeviceTypes() throws {
        let runner = RecordingCommandRunner()
        let runtime = RuntimeInfo(
            version: "27.0",
            build: "24A5355q",
            identifier: "ios-27",
            runtimeRoot: "/runtimes/27"
        )
        runner.setCaptureOutput(
            """
            {
              "devicetypes": [
                {
                  "name": "iPhone 14",
                  "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-14",
                  "productFamily": "iPhone",
                  "minRuntimeVersion": \(coreSimulatorRuntimeVersion(16)),
                  "maxRuntimeVersion": \(coreSimulatorRuntimeVersion(26, 4))
                },
                {
                  "name": "iPhone 17e",
                  "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17e",
                  "productFamily": "iPhone",
                  "minRuntimeVersion": \(coreSimulatorRuntimeVersion(27, 1)),
                  "maxRuntimeVersion": \(coreSimulatorRuntimeVersion(28))
                },
                {
                  "name": "iPhone 17",
                  "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
                  "productFamily": "iPhone",
                  "minRuntimeVersion": \(coreSimulatorRuntimeVersion(27)),
                  "maxRuntimeVersion": \(coreSimulatorRuntimeVersion(28))
                },
                {
                  "name": "iPad Pro",
                  "identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro",
                  "productFamily": "iPad",
                  "minRuntimeVersion": \(coreSimulatorRuntimeVersion(27)),
                  "maxRuntimeVersion": \(coreSimulatorRuntimeVersion(28))
                }
              ]
            }
            """,
            for: ["xcrun", "simctl", "list", "devicetypes", "-j"]
        )

        try Simctl.createDefaultDevice(runtime: runtime, runner: runner, environment: [:])

        #expect(runner.simpleCommands.map(\.command) == [
            [
                "xcrun",
                "simctl",
                "create",
                "iPhone 17 (27.0)",
                "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
                "ios-27",
            ],
        ])
    }

    @Test func createDefaultDeviceFallsBackToFirstIPhoneWhenCompatibilityMetadataIsAbsent() throws {
        let runner = RecordingCommandRunner()
        let runtime = RuntimeInfo(
            version: "27.0",
            build: "24A5355q",
            identifier: "ios-27",
            runtimeRoot: "/runtimes/27"
        )
        runner.setCaptureOutput(
            """
            {
              "devicetypes": [
                {
                  "name": "iPad Pro",
                  "identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro",
                  "productFamily": "iPad"
                },
                {
                  "name": "iPhone 16",
                  "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16",
                  "productFamily": "iPhone"
                }
              ]
            }
            """,
            for: ["xcrun", "simctl", "list", "devicetypes", "-j"]
        )

        try Simctl.createDefaultDevice(runtime: runtime, runner: runner, environment: [:])

        #expect(runner.simpleCommands.map(\.command) == [
            [
                "xcrun",
                "simctl",
                "create",
                "iPhone 16 (27.0)",
                "com.apple.CoreSimulator.SimDeviceType.iPhone-16",
                "ios-27",
            ],
        ])
    }
}

private func coreSimulatorRuntimeVersion(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) -> Int {
    (major << 16) | (minor << 8) | patch
}
