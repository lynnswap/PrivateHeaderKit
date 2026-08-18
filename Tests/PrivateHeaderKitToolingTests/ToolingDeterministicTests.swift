import Foundation
import Testing
@testable import PrivateHeaderKitTooling
import PrivateHeaderKitTestSupport

@Suite
struct PathAndVersionTests {
    @Test func simulatorPlatformOwnsSDKTripleAndDeviceFamily() {
        #expect(SimulatorPlatform.iOS.sdkName == "iphonesimulator")
        #expect(
            SimulatorPlatform.iOS.swiftPMTriple(architecture: "arm64")
                == "arm64-apple-ios-simulator"
        )
        #expect(SimulatorPlatform.iOS.preferredDeviceFamily == "iPhone")
        #expect(SimulatorPlatform.watchOS.sdkName == "watchsimulator")
        #expect(
            SimulatorPlatform.watchOS.swiftPMTriple(architecture: "arm64")
                == "arm64-apple-watchos-simulator"
        )
        #expect(SimulatorPlatform.watchOS.preferredDeviceFamily == "Apple Watch")
    }

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

    @Test func whichResolvesRelativeAndEmbeddedEmptyPathEntriesFromTheWorkingDirectory() throws {
        let dirs = try makeTemporaryTestDirectories()
        let binDir = dirs.root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let cwdExecutable = dirs.root.appendingPathComponent("cwd-tool", isDirectory: false)
        let relativeExecutable = binDir.appendingPathComponent("relative-tool", isDirectory: false)
        for executable in [cwdExecutable, relativeExecutable] {
            try Data("#!/bin/sh\n".utf8).write(to: executable)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
        }

        #expect(
            Which.findAll(
                "cwd-tool",
                environment: ["PATH": ":/usr/bin:"],
                currentDirectory: dirs.root
            ).map(\.path) == [cwdExecutable.path]
        )
        #expect(
            Which.findAll(
                "relative-tool",
                environment: ["PATH": "bin"],
                currentDirectory: dirs.root
            ).map(\.path) == [relativeExecutable.path]
        )
        #expect(
            Which.findAll(
                "cwd-tool",
                environment: ["PATH": ""],
                currentDirectory: dirs.root
            ).isEmpty
        )
    }
}

@Suite
struct SimctlDeterministicTests {
    @Test func listRuntimesParsesSupportedPlatformsInPlatformAndVersionOrder() async throws {
        let runner = RecordingCommandRunner()
        await runner.setCaptureOutput(
            """
            {
              "runtimes": [
                {
                  "name": "iOS 26.10",
                  "platform": "iOS",
                  "version": "26.10",
                  "identifier": "ios-26-10",
                  "runtimeRoot": "/runtimes/26.10",
                  "isAvailable": true,
                  "buildversion": "23Z1",
                  "supportedDeviceTypes": [
                    {"name":"iPhone 17","identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17","productFamily":"iPhone"}
                  ]
                },
                {"name": "iOS 26.2", "platform": "iOS", "version": "26.2", "identifier": "ios-26-2", "runtimeRoot": "/runtimes/26.2", "isAvailable": true, "buildversion": "23C54"},
                {"name": "iOS 25.0", "platform": "iOS", "version": "25.0", "identifier": "ios-25-0", "runtimeRoot": "/runtimes/25.0", "isAvailable": false},
                {"name": "watchOS 26.0", "platform": "watchOS", "version": "26.0", "identifier": "watch-26-0", "runtimeRoot": "/runtimes/watch", "isAvailable": true, "buildversion": "23T1"},
                {"name": "tvOS 26.0", "platform": "tvOS", "version": "26.0", "identifier": "tv-26-0", "runtimeRoot": "/runtimes/tv", "isAvailable": true}
              ]
            }
            """,
            for: ["xcrun", "simctl", "list", "runtimes", "-j"]
        )

        let runtimes = try await Simctl.listRuntimes(runner: runner)

        #expect(runtimes.map(\.platform) == [.iOS, .iOS, .watchOS])
        #expect(runtimes.map(\.version) == ["26.2", "26.10", "26.0"])
        #expect(runtimes.first?.build == "23C54")
        #expect(
            runtimes.first(where: { $0.platform == .iOS && $0.version == "26.10" })?
                .supportedDeviceTypes.first?.identifier
                == "com.apple.CoreSimulator.SimDeviceType.iPhone-17"
        )
        #expect(await runner.captureCommandSnapshot().map(\.command) == [["xcrun", "simctl", "list", "runtimes", "-j"]])
    }

    @Test func listRuntimesRequiresExplicitPlatformMetadata() async {
        let runner = RecordingCommandRunner()
        await runner.setCaptureOutput(
            """
            {"runtimes":[{"name":"iOS 27.0","version":"27.0","identifier":"ios-27","runtimeRoot":"/runtimes/27","isAvailable":true}]}
            """,
            for: ["xcrun", "simctl", "list", "runtimes", "-j"]
        )

        await #expect(throws: DecodingError.self) {
            _ = try await Simctl.listRuntimes(runner: runner)
        }
    }

    @Test func findRuntimeSeparatesPlatformsWithTheSameVersionAndBuild() async throws {
        let runner = RecordingCommandRunner()
        await runner.setCaptureOutput(
            """
            {"runtimes":[
              {"name":"iOS 27.0","platform":"iOS","version":"27.0","buildversion":"24A1","identifier":"ios-27","runtimeRoot":"/runtimes/iOS","isAvailable":true},
              {"name":"watchOS 27.0","platform":"watchOS","version":"27.0","buildversion":"24A1","identifier":"watch-27","runtimeRoot":"/runtimes/watchOS","isAvailable":true}
            ]}
            """,
            for: ["xcrun", "simctl", "list", "runtimes", "-j"]
        )

        let ios = try await Simctl.findRuntime(
            platform: .iOS,
            version: "27.0",
            build: "24A1",
            runner: runner
        )
        let watchOS = try await Simctl.findRuntime(
            platform: .watchOS,
            version: "27.0",
            build: "24A1",
            runner: runner
        )

        #expect(ios.identifier == "ios-27")
        #expect(watchOS.identifier == "watch-27")
    }

    @Test func listRuntimesOrdersEqualVersionsByBuildAndIdentity() async throws {
        let runner = RecordingCommandRunner()
        await runner.setCaptureOutput(
            """
            {
              "runtimes": [
                {"name": "iOS 27.0", "platform": "iOS", "version": "27.0", "identifier": "ios-27-z", "runtimeRoot": "/runtimes/Z", "isAvailable": true, "buildversion": "24B2"},
                {"name": "iOS 27.0", "platform": "iOS", "version": "27.0", "identifier": "ios-27-b", "runtimeRoot": "/runtimes/B", "isAvailable": true, "buildversion": "24A1"},
                {"name": "iOS 27.0", "platform": "iOS", "version": "27.0", "identifier": "ios-27-a", "runtimeRoot": "/runtimes/A", "isAvailable": true, "buildversion": "24A1"}
              ]
            }
            """,
            for: ["xcrun", "simctl", "list", "runtimes", "-j"]
        )

        let runtimes = try await Simctl.listRuntimes(runner: runner)

        #expect(runtimes.map(\.identifier) == ["ios-27-a", "ios-27-b", "ios-27-z"])
    }

    @Test func findRuntimeMatchesExplicitBuildWhenProvided() async throws {
        let runner = RecordingCommandRunner()
        await runner.setCaptureOutput(
            """
            {
              "runtimes": [
                {"name": "iOS 27.0", "platform": "iOS", "version": "27.0", "identifier": "ios-27-a", "runtimeRoot": "/runtimes/27A", "isAvailable": true, "buildversion": "24A1"},
                {"name": "iOS 27.0", "platform": "iOS", "version": "27.0", "identifier": "ios-27-b", "runtimeRoot": "/runtimes/27B", "isAvailable": true, "buildversion": "24B2"}
              ]
            }
            """,
            for: ["xcrun", "simctl", "list", "runtimes", "-j"]
        )

        let runtime = try await Simctl.findRuntime(
            platform: .iOS,
            version: "27.0",
            build: "24B2",
            runner: runner
        )

        #expect(runtime.identifier == "ios-27-b")
        #expect(runtime.runtimeRoot == "/runtimes/27B")
    }

    @Test func findRuntimeRejectsDuplicateExplicitBuildRegardlessOfInputOrder() async {
        let entries = [
            """
            {"name": "iOS 27.0", "platform": "iOS", "version": "27.0", "identifier": "ios-27-b", "runtimeRoot": "/runtimes/27B", "isAvailable": true, "buildversion": "24A1"}
            """,
            """
            {"name": "iOS 27.0", "platform": "iOS", "version": "27.0", "identifier": "ios-27-a", "runtimeRoot": "/runtimes/27A", "isAvailable": true, "buildversion": "24A1"}
            """,
        ]
        let expectedError = "multiple available iOS runtimes match version 27.0 build 24A1: "
            + "ios-27-a [/runtimes/27A], ios-27-b [/runtimes/27B]; "
            + "remove the duplicate runtime installation"

        for orderedEntries in [entries, Array(entries.reversed())] {
            let runner = RecordingCommandRunner()
            await runner.setCaptureOutput(
                """
                {"runtimes":[\(orderedEntries.joined(separator: ","))]}
                """,
                for: ["xcrun", "simctl", "list", "runtimes", "-j"]
            )

            let error = await runtimeResolutionError {
                try await Simctl.findRuntime(
                    platform: .iOS,
                    version: "27.0",
                    build: "24A1",
                    runner: runner
                )
            }
            #expect(error == expectedError)
        }
    }

    @Test func findRuntimeWithoutBuildReturnsUniqueVersionMatch() async throws {
        let runner = RecordingCommandRunner()
        await runner.setCaptureOutput(
            """
            {
              "runtimes": [
                {"name": "iOS 26.0", "platform": "iOS", "version": "26.0", "identifier": "ios-26", "runtimeRoot": "/runtimes/26", "isAvailable": true, "buildversion": "23A1"},
                {"name": "iOS 27.0", "platform": "iOS", "version": "27.0", "identifier": "ios-27", "runtimeRoot": "/runtimes/27", "isAvailable": true, "buildversion": "24A1"}
              ]
            }
            """,
            for: ["xcrun", "simctl", "list", "runtimes", "-j"]
        )

        let runtime = try await Simctl.findRuntime(
            platform: .iOS,
            version: "27.0",
            build: nil,
            runner: runner
        )

        #expect(runtime.identifier == "ios-27")
    }

    @Test func findRuntimeWithoutBuildRejectsAmbiguousBuildsRegardlessOfInputOrder() async {
        let entries = [
            """
            {"name": "iOS 27.0", "platform": "iOS", "version": "27.0", "identifier": "ios-27-a", "runtimeRoot": "/runtimes/27A", "isAvailable": true, "buildversion": "24A1"}
            """,
            """
            {"name": "iOS 27.0", "platform": "iOS", "version": "27.0", "identifier": "ios-27-b", "runtimeRoot": "/runtimes/27B", "isAvailable": true, "buildversion": "24B2"}
            """,
        ]
        let expectedError = "multiple available iOS runtimes match version 27.0 "
            + "(builds: 24A1, 24B2); specify --build"

        for orderedEntries in [entries, Array(entries.reversed())] {
            let runner = RecordingCommandRunner()
            await runner.setCaptureOutput(
                """
                {"runtimes":[\(orderedEntries.joined(separator: ","))]}
                """,
                for: ["xcrun", "simctl", "list", "runtimes", "-j"]
            )

            let error = await runtimeResolutionError {
                try await Simctl.findRuntime(
                    platform: .iOS,
                    version: "27.0",
                    build: nil,
                    runner: runner
                )
            }
            #expect(error == expectedError)
        }
    }

    @Test func listDevicesParsesDevicesForRuntime() async throws {
        let runner = RecordingCommandRunner()
        await runner.setCaptureOutput(
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

        let devices = try await Simctl.listDevices(runtimeId: "ios-26-2", runner: runner)

        #expect(devices.map(\.udid) == ["A", "B"])
        #expect(devices.map(\.state) == ["Shutdown", "Booted"])
    }

    @Test func ensureDeviceBootedSkipsBootedDeviceUnlessForced() async throws {
        let runner = RecordingCommandRunner()
        let booted = DeviceInfo(name: "iPhone", udid: "BOOTED", state: "Booted")

        let unchanged = try await Simctl.ensureDeviceBooted(booted, runner: runner, force: false)
        #expect(unchanged == booted)
        #expect(await runner.simpleCommandSnapshot().isEmpty)

        let forced = try await Simctl.ensureDeviceBooted(booted, runner: runner, force: true)
        #expect(forced.state == "Booted")
        #expect(await runner.simpleCommandSnapshot().map(\.command) == [
            ["xcrun", "simctl", "boot", "BOOTED"],
            ["xcrun", "simctl", "bootstatus", "BOOTED", "-b"],
        ])
    }

    @Test func resolveDeviceCreatesRelistsClonesAndBootsWhenRuntimeHasNoDevices() async throws {
        let runner = RecordingCommandRunner()
        let runtime = RuntimeInfo(
            platform: .iOS,
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
        await runner.setCaptureOutputs(
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
        await runner.setCaptureOutput(
            "CLONE-001\n",
            for: ["xcrun", "simctl", "clone", "BASE-001", "Dumping Device (iOS 27.0)"]
        )

        let device = try await Simctl.resolveDevice(runtime: runtime, query: nil, runner: runner, environment: [:])

        #expect(device.name == "Dumping Device (iOS 27.0)")
        #expect(device.udid == "CLONE-001")
        #expect(device.state == "Booted")
        #expect(await runner.simpleCommandSnapshot().map(\.command) == [
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
        let capturedCommands = await runner.captureCommandSnapshot().map(\.command)
        #expect(!capturedCommands.contains(["xcrun", "simctl", "list", "devicetypes", "-j"]))
    }

    @Test func createDefaultDeviceFallsBackToRuntimeCompatibleDeviceTypes() async throws {
        let runner = RecordingCommandRunner()
        let runtime = RuntimeInfo(
            platform: .iOS,
            version: "27.0",
            build: "24A5355q",
            identifier: "ios-27",
            runtimeRoot: "/runtimes/27"
        )
        await runner.setCaptureOutput(
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

        try await Simctl.createDefaultDevice(runtime: runtime, runner: runner, environment: [:])

        #expect(await runner.simpleCommandSnapshot().map(\.command) == [
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

    @Test func createDefaultDeviceFallsBackToNumericRuntimeCompatibleDeviceTypes() async throws {
        let runner = RecordingCommandRunner()
        let runtime = RuntimeInfo(
            platform: .iOS,
            version: "27.0",
            build: "24A5355q",
            identifier: "ios-27",
            runtimeRoot: "/runtimes/27"
        )
        await runner.setCaptureOutput(
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

        try await Simctl.createDefaultDevice(runtime: runtime, runner: runner, environment: [:])

        #expect(await runner.simpleCommandSnapshot().map(\.command) == [
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

    @Test func createDefaultDeviceFallsBackToFirstIPhoneWhenCompatibilityMetadataIsAbsent() async throws {
        let runner = RecordingCommandRunner()
        let runtime = RuntimeInfo(
            platform: .iOS,
            version: "27.0",
            build: "24A5355q",
            identifier: "ios-27",
            runtimeRoot: "/runtimes/27"
        )
        await runner.setCaptureOutput(
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

        try await Simctl.createDefaultDevice(runtime: runtime, runner: runner, environment: [:])

        #expect(await runner.simpleCommandSnapshot().map(\.command) == [
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

    @Test func createDefaultWatchDevicePrefersAppleWatchFamily() async throws {
        let runner = RecordingCommandRunner()
        let runtime = RuntimeInfo(
            platform: .watchOS,
            version: "27.0",
            build: "24R5325f",
            identifier: "watch-27",
            runtimeRoot: "/runtimes/watch-27",
            supportedDeviceTypes: [
                DeviceTypeInfo(
                    name: "iPhone 17",
                    identifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
                    productFamily: "iPhone"
                ),
                DeviceTypeInfo(
                    name: "Apple Watch Series 11 (46mm)",
                    identifier: "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-11-46mm",
                    productFamily: "Apple Watch"
                ),
            ]
        )

        try await Simctl.createDefaultDevice(runtime: runtime, runner: runner, environment: [:])

        #expect(
            Simctl.defaultCloneName(platform: .watchOS, version: "27.0")
                == "Dumping Device (watchOS 27.0)"
        )
        #expect(await runner.simpleCommandSnapshot().map(\.command) == [
            [
                "xcrun",
                "simctl",
                "create",
                "Apple Watch Series 11 (46mm) (27.0)",
                "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-11-46mm",
                "watch-27",
            ],
        ])
    }
}

private func runtimeResolutionError(
    _ operation: () async throws -> RuntimeInfo
) async -> String? {
    do {
        _ = try await operation()
        Issue.record("expected runtime resolution to fail")
        return nil
    } catch let error as ToolingError {
        return error.description
    } catch {
        Issue.record("unexpected error: \(error)")
        return nil
    }
}

private func coreSimulatorRuntimeVersion(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) -> Int {
    (major << 16) | (minor << 8) | patch
}
