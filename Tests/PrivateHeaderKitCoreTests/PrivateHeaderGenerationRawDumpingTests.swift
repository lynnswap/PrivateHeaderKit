import Foundation
import Testing

@testable import PrivateHeaderKitCore

@Suite
struct PrivateHeaderGenerationRawDumpingTests {
  @Test func hostInvocationUsesOnlyTheSelectedHelperAndStableFlags() {
    let invocation = PrivateHeaderGeneration.RawDumping.makeInvocation(
      .init(
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
        )
      )
    )

    #expect(invocation.helperURL == helperURLs.host)
    #expect(
      invocation.command == [
        "/opt/privateheaderkit/bin/privateheaderkit", "__raw-dump", "-o", stageDirectory.path,
        "-b", "-h", "-s", "-c", "-D", "-R",
        "/System/Library/PrivateFrameworks/Foo.framework",
      ])
    #expect(invocation.environment == ["PH_PROFILE": "1"])
  }

  @Test func simulatorInvocationUsesSimctlAndOverridesRuntimeEnvironment() {
    let runtimeRoot = "/Library/Developer/CoreSimulator/RuntimeRoot"
    let invocation = PrivateHeaderGeneration.RawDumping.makeInvocation(
      .init(
        helperURLs: helperURLs,
        executionMode: .simulator(deviceUDID: "SIM-001", runtimeRoot: runtimeRoot),
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
        "/System/Library/Frameworks/UIKit.framework",
      ])
    #expect(
      invocation.environment == [
        "SIMCTL_CHILD_DYLD_ROOT_PATH": runtimeRoot,
        "SIMCTL_CHILD_PH_PROFILE": "1",
        "SIMCTL_CHILD_PH_RUNTIME_ROOT": runtimeRoot,
      ])
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
