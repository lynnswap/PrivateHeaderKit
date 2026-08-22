import Foundation
import Testing

@testable import PrivateHeaderKitCore

@Suite
struct PrivateHeaderGenerationRawDumpingTests {
  @Test func hostInvocationUsesOnlyTheSelectedHelperAndStableFlags() throws {
    let cacheUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let invocation = PrivateHeaderGeneration.RawDumping.makeInvocation(
      try .init(
        helperURLs: helperURLs,
        executionMode: .host,
        inputPath: "/System/Library/PrivateFrameworks/Foo.framework",
        stagingOutputDirectory: stageDirectory,
        options: .init(
          skipExisting: true,
          useSharedCache: true,
          verbose: true,
          preferRuntimeMetadata: true,
          helperEnvironment: ["PH_PROFILE": "1"]
        ),
        expectedCacheUUID: cacheUUID
      )
    )

    #expect(invocation.helperURL == helperURLs.host)
    #expect(
      invocation.diagnosticsReportURL.deletingLastPathComponent()
        == stageDirectory.deletingLastPathComponent()
    )
    #expect(
      invocation.command == [
        "/opt/privateheaderkit/bin/privateheaderkit", "__raw-dump", "-o", stageDirectory.path,
        "-b", "-h", "-s", "-c", "--expected-cache-uuid",
        cacheUUID.uuidString.lowercased(), "-D", "-R", "--diagnostics-report",
        invocation.diagnosticsReportURL.path,
        "/System/Library/PrivateFrameworks/Foo.framework",
      ])
    #expect(invocation.environment == ["PH_PROFILE": "1"])
  }

  @Test func simulatorInvocationUsesSimctlAndOverridesRuntimeEnvironment() throws {
    let runtimeRoot = "/Library/Developer/CoreSimulator/RuntimeRoot"
    let invocation = PrivateHeaderGeneration.RawDumping.makeInvocation(
      try .init(
        helperURLs: helperURLs,
        executionMode: simulatorExecutionMode(runtimeRoot: runtimeRoot),
        inputPath: "/System/Library/Frameworks/UIKit.framework",
        stagingOutputDirectory: stageDirectory,
        options: .init(
          preferRuntimeMetadata: true,
          helperEnvironment: [
            "SIMCTL_CHILD_DYLD_ROOT_PATH": "/wrong",
            "SIMCTL_CHILD_PH_PROFILE": "1",
          ]
        )
      )
    )

    #expect(invocation.helperURL == helperURLs.simulator)
    #expect(
      invocation.command == [
        "xcrun", "simctl", "spawn", "SIM-001", "/opt/privateheaderkit/bin/privateheaderkit-sim",
        "__raw-dump", "-o", stageDirectory.path, "-b", "-h",
        "--diagnostics-report", invocation.diagnosticsReportURL.path,
        "/System/Library/Frameworks/UIKit.framework",
      ])
    #expect(
      invocation.environment == [
        "SIMCTL_CHILD_DYLD_ROOT_PATH": runtimeRoot,
        "SIMCTL_CHILD_PH_PROFILE": "1",
        "SIMCTL_CHILD_PH_RUNTIME_ROOT": runtimeRoot,
      ])
  }

  @Test func sharedCacheInventoryInvocationUsesSelectedHostHelper() {
    let invocation = PrivateHeaderGeneration.RawDumping.makeSharedCacheInventoryInvocation(
      helperURLs: helperURLs,
      executionMode: .host,
      helperEnvironment: ["PH_PROFILE": "1"]
    )

    #expect(invocation.phaseLabel == "shared-cache-inventory")
    #expect(invocation.helperURL == helperURLs.host)
    #expect(invocation.command == [helperURLs.host.path, "__shared-cache-inventory"])
    #expect(invocation.environment == ["PH_PROFILE": "1"])
  }

  @Test func sharedCacheInventoryInvocationUsesSimulatorRuntimeCohort() {
    let runtimeRoot = "/Library/Developer/CoreSimulator/RuntimeRoot"
    let invocation = PrivateHeaderGeneration.RawDumping.makeSharedCacheInventoryInvocation(
      helperURLs: helperURLs,
      executionMode: simulatorExecutionMode(runtimeRoot: runtimeRoot),
      helperEnvironment: ["SIMCTL_CHILD_PH_PROFILE": "1"]
    )

    #expect(
      invocation.command == [
        "xcrun", "simctl", "spawn", "SIM-001", helperURLs.simulator.path,
        "__shared-cache-inventory",
      ])
    #expect(
      invocation.environment == [
        "SIMCTL_CHILD_DYLD_ROOT_PATH": runtimeRoot,
        "SIMCTL_CHILD_PH_PROFILE": "1",
        "SIMCTL_CHILD_PH_RUNTIME_ROOT": runtimeRoot,
      ])
  }

  @Test func requestRequiresCacheUUIDExactlyWhenSharedCacheIsEnabled() {
    let cacheUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    #expect(throws: PrivateHeaderGeneration.RawDumping.Request.ValidationError.self) {
      _ = try PrivateHeaderGeneration.RawDumping.Request(
        helperURLs: helperURLs,
        executionMode: .host,
        inputPath: "/usr/lib/libobjc.A.dylib",
        stagingOutputDirectory: stageDirectory,
        options: .init(useSharedCache: true)
      )
    }
    #expect(throws: PrivateHeaderGeneration.RawDumping.Request.ValidationError.self) {
      _ = try PrivateHeaderGeneration.RawDumping.Request(
        helperURLs: helperURLs,
        executionMode: .host,
        inputPath: "/usr/lib/libobjc.A.dylib",
        stagingOutputDirectory: stageDirectory,
        expectedCacheUUID: cacheUUID
      )
    }
  }

  @Test func killedResultNeverSucceedsEvenWithZeroExitStatus() {
    #expect(
      !PrivateHeaderGeneration.RawDumping.Result(terminationStatus: 0, wasKilled: true).succeeded)
    #expect(PrivateHeaderGeneration.RawDumping.Result(terminationStatus: 0).succeeded)
  }

  private let helperURLs = PrivateHeaderGeneration.RawDumping.HelperURLs(
    host: URL(fileURLWithPath: "/opt/privateheaderkit/bin/privateheaderkit"),
    simulator: URL(fileURLWithPath: "/opt/privateheaderkit/bin/privateheaderkit-sim")
  )
  private let stageDirectory = URL(
    fileURLWithPath: "/tmp/PrivateHeaderKit/staging", isDirectory: true)
}

private func simulatorExecutionMode(
  runtimeRoot: String
) -> PrivateHeaderGeneration.RawDumping.ExecutionMode {
  .simulator(
    deviceUDID: "SIM-001",
    sourceRuntimeRoot: runtimeRoot,
    runtime: .init(
      version: "27.0",
      build: "24A5355q",
      identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
      runtimeRoot: runtimeRoot
    )
  )
}
