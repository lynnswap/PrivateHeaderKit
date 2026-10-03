import Foundation
import PrivateHeaderKitCore
import PrivateHeaderKitHelperProtocol
import PrivateHeaderKitTestSupport
import PrivateHeaderKitTooling
import Testing
@testable import PrivateHeaderKitCLI

struct PrivateHeaderKitSSHApplicationTests {
  @Test(arguments: [["--app", "com.example.Sample"], ["--pid", "1234"]])
  func applicationSelectionUsesTheExistingSSHFlow(selector: [String]) throws {
    let parsed = try parsePrivateHeaderKitCommand(["privateheaderkit", "--ssh", "device", "--out", "/tmp/output"] + selector + ["--include-binary", "--resume"])
    guard case .generateSSH(let command) = parsed else { Issue.record("expected SSH generation"); return }
    #expect(command.application != nil)
    #expect(command.includesAnalysisBinary)
    #expect(command.continuationMode == .resume)
  }

  @Test(arguments: [
    ["--app", "com.example.Sample", "--pid", "1234"],
    ["--app", "com.example.Sample", "--target", "all"],
    ["--app", "com.example.Sample", "--runtime-metadata"],
    ["--pid", "0"], ["--pid", "-1"], ["--include-binary", "--target", "all"]
  ])
  func conflictingApplicationOptionsFailBeforeConnecting(options: [String]) {
    #expect(throws: (any Error).self) {
      try parsePrivateHeaderKitCommand(["privateheaderkit", "--ssh", "device", "--out", "/tmp/output"] + options)
    }
  }

  @Test(arguments: ["uuid", "cpu", "path", "pid"])
  func recoveryRejectsChangedProcessImageIdentity(field: String) async throws {
    let fixture = ApplicationSSHFixture()
    let runner = RecordingCommandRunner()
    let session = PrivateHeaderKitSSHSession(destination: "device", processRunner: runner)
    await runner.setCaptureHandler { command, _, _ in
      if command.last?.contains("__running-application") == true { return try fixture.applicationJSON() }
      return try fixture.recoveryJSON(path: session.directory + "/application-input/Executable", changedField: field)
    }
    await #expect(throws: (any Error).self) {
      try await session.recoverApplication(.processIdentifier(1234), localDirectory: .temporaryDirectory, includesBinary: false)
    }
    let cleanup = try #require(await runner.simpleCommandSnapshot().last)
    #expect(cleanup.command.last?.contains("owned helper PID no longer matches invocation") == true)
    #expect(cleanup.command.last?.contains("application-input/Executable") == true)
  }

  @Test func recoveredAnalysisBinaryUsesOwnedTransportAndSourceOSMetadata() async throws {
    let directory = URL.temporaryDirectory.appendingPathComponent("ApplicationSSHTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = ApplicationSSHFixture()
    let runner = RecordingCommandRunner()
    let session = PrivateHeaderKitSSHSession(destination: "vphone", processRunner: runner)
    await runner.setCaptureHandler { command, _, _ in
      if command.last?.contains("__running-application") == true { return try fixture.applicationJSON() }
      #expect(command.last?.contains("--expected-uuid") == true)
      return try fixture.recoveryJSON(path: session.directory + "/application-input/Executable", changedField: "none")
    }
    await runner.setCaptureChunksHandler { command, _, _, consume in
      #expect(command.last?.contains("cat") == true)
      #expect(command.last?.contains(session.directory + "/application-input/Executable") == true)
      try await consume(Data("analysis fixture".utf8))
    }
    let recovered = try await session.recoverApplication(.bundleIdentifier("com.example.Sample"), localDirectory: directory, includesBinary: true)
    #expect(recovered.systemVersion.version == "26.0")
    #expect(recovered.snapshot.identity.executableUUID == fixture.uuid)
    #expect(try Data(contentsOf: #require(recovered.snapshot.localBinaryURL)) == Data("analysis fixture".utf8))
    #expect(await runner.captureCommandSnapshot().count == 3)
    #expect(!recovered.snapshot.logicalImagePath.contains(session.directory))
  }

  @Test func recoveryAndOwnedHelperCleanupFailuresAreBothReported() async throws {
    let fixture = ApplicationSSHFixture()
    let runner = RecordingCommandRunner()
    let session = PrivateHeaderKitSSHSession(destination: "device", processRunner: runner)
    await runner.setCaptureHandler { command, _, _ in
      if command.last?.contains("__running-application") == true { return try fixture.applicationJSON() }
      throw ToolingError.message("fixture recovery read failed")
    }
    await runner.setSimpleHandler { command, _, _ in
      if command.last?.contains("owned helper PID") == true { throw ToolingError.message("fixture helper cleanup failed") }
    }
    do {
      _ = try await session.recoverApplication(.bundleIdentifier("com.example.Sample"), localDirectory: .temporaryDirectory, includesBinary: false)
      Issue.record("failed recovery unexpectedly succeeded")
    } catch {
      #expect(String(describing: error).contains("fixture recovery read failed"))
      #expect(String(describing: error).contains("fixture helper cleanup failed"))
    }
  }
}

private struct ApplicationSSHFixture: Sendable {
  let uuid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
  var image: PrivateHeaderKitProcessImage {
    .init(loadAddress: 0x1000, path: "/Applications/Sample.app/Executable", uuid: uuid, cpuType: 16777228, cpuSubtype: 0, fileType: 2)
  }
  func applicationJSON() throws -> String {
    String(decoding: try JSONEncoder().encode(PrivateHeaderKitRunningApplicationReport(application: .init(
      processIdentifier: 1234, bundleIdentifier: "com.example.Sample", version: "1.0", build: "1", executableName: "Executable", mainImage: image
    ), systemVersion: .init(version: "26.0", build: "23A100", metadataIsSeed: false))), as: UTF8.self)
  }
  func recoveryJSON(path: String, changedField: String) throws -> String {
    let changedImage = PrivateHeaderKitProcessImage(
      loadAddress: image.loadAddress, path: changedField == "path" ? "/Applications/Other.app/Executable" : image.path,
      uuid: changedField == "uuid" ? UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")! : image.uuid,
      cpuType: image.cpuType, cpuSubtype: changedField == "cpu" ? 2 : image.cpuSubtype, fileType: image.fileType
    )
    return String(decoding: try JSONEncoder().encode(PrivateHeaderKitRecoveredProcessImage(
      processIdentifier: changedField == "pid" ? 1235 : 1234, image: changedImage,
      outputPath: path, encryptedBytesRecovered: 4096
    )), as: UTF8.self)
  }
}
