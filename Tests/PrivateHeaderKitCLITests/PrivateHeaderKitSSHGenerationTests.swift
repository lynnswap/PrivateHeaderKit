import Foundation
import PrivateHeaderKitCore
import PrivateHeaderKitHelperProtocol
import PrivateHeaderKitTestSupport
import PrivateHeaderKitTooling
import Testing

@testable import PrivateHeaderKitCLI

@Suite
struct PrivateHeaderKitSSHGenerationTests {
  @Test(arguments: ["iphone-se", "ssh://mobile@127.0.0.1:2222"], [false, true])
  func sshSourceUsesPeerMetadataWithoutLocalSourceArguments(destination: String, usesAlias: Bool) throws {
    let arguments = ["privateheaderkit"] + (usesAlias ? ["generate"] : []) + [
      "--ssh", destination, "--out", "/tmp/Headers", "--target", "SpringBoard,SpringBoardUI", "--resume",
    ]
    guard case .generateSSH(let command) = try parsePrivateHeaderKitCommand(arguments) else {
      Issue.record("SSH generation did not produce an SSH command")
      return
    }
    #expect(command.destination == destination)
    #expect(command.outputBaseDirectory == "/tmp/Headers")
    #expect(command.targetQuery == "SpringBoard,SpringBoardUI")
    #expect(command.executionOptions.continuation == .resume)
    #expect(!command.preferRuntimeMetadata)
  }

  @Test func sshRuntimeMetadataRequiresAnExplicitOption() throws {
    guard case .generateSSH(let command) = try parsePrivateHeaderKitCommand([
      "privateheaderkit", "--ssh", "iphone-se", "--runtime-metadata",
      "--out", "/tmp/Headers", "--target", "SpringBoard",
    ]) else {
      Issue.record("SSH runtime metadata did not produce an SSH command")
      return
    }
    #expect(command.preferRuntimeMetadata)
  }

  @Test func sshBootstrapSetsPATHBeforeLaunchingTheQuotedShellPayload() async throws {
    let payload = "root literal $PHK_LITERAL_MARKER $(printf substituted)"
    let command = PrivateHeaderGeneration.RawDumping.sshCommand(
      destination: "iphone-se", script: "printf '%s' '" + payload + "'"
    )
    let remoteCommand = try #require(command.last)
    #expect(remoteCommand.hasPrefix("export PATH="))
    #expect(remoteCommand.contains("; exec sh -c '"))

    let output = try await ProcessRunner().runCapture(
      ["/bin/sh", "-c", remoteCommand],
      env: ["PATH": "/unavailable", "PHK_LITERAL_MARKER": "expanded"], cwd: nil
    )
    #expect(output == payload)
  }

  @Test(arguments: [
    ["--platform", "iOS"], ["--version", "26.0.1"], ["--build", "23A355"],
    ["--system-root", "/"], ["--device", "Simulator"], ["--sim-helper", "/tmp/helper"],
  ])
  func sshSourceRejectsConflictingLocalSourceOptions(option: [String]) async {
    let errors = SSHTestMessages()
    let status = await runPrivateHeaderKitCommand(
      ["privateheaderkit", "--ssh", "iphone-se", "--out", "/tmp/Headers", "--target", "all"] + option,
      currentExecutableURL: nil, outputLogger: { _ in }, errorLogger: errors.append
    )
    #expect(status != 0)
    #expect(errors.text.contains("--ssh reads the source OS from the peer"))
  }

  @Test(arguments: [
    (["--ssh", "iphone-se", "--target", "all"], "--out"),
    (["--ssh", "iphone-se", "--out", "/tmp/Headers"], "--target"),
    (["--ssh", "", "--out", "/tmp/Headers", "--target", "all"], "--ssh"),
  ])
  func incompleteSSHInputsReportTheMissingInput(arguments: [String], expectedOption: String) async {
    let errors = SSHTestMessages()
    let status = await runPrivateHeaderKitCommand(
      ["privateheaderkit"] + arguments, currentExecutableURL: nil,
      outputLogger: { _ in }, errorLogger: errors.append
    )
    #expect(status != 0)
    #expect(errors.text.contains(expectedOption))
  }

  @Test func toolVersionWithSSHOptionsHasNoTransportSideEffects() async {
    let runner = RecordingCommandRunner()
    let output = SSHTestMessages()
    let status = await runPrivateHeaderKitCommand(
      ["privateheaderkit", "--tool-version", "--ssh", "iphone-se"],
      currentExecutableURL: nil, sshProcessRunner: runner,
      outputLogger: output.append, errorLogger: { _ in }
    )
    #expect(status == 0)
    #expect(output.text.trimmingCharacters(in: .newlines) == PrivateHeaderKitBuildInfo.version)
    #expect(await runner.captureCommandSnapshot().isEmpty)
    #expect(await runner.inputCommandSnapshot().isEmpty)
    #expect(await runner.simpleCommandSnapshot().isEmpty)
    #expect(await runner.interactiveCommandSnapshot().isEmpty)
  }

  @Test func sessionDeploysBinaryInputAndReadsPeerSnapshotThroughSSH() async throws {
    let fixture = try SSHGenerationFixture()
    defer { fixture.cleanup() }
    let runner = RecordingCommandRunner()
    let session = PrivateHeaderKitSSHSession(destination: "ssh://mobile@127.0.0.1:2222", processRunner: runner)
    defer { try? FileManager.default.removeItem(at: session.controlDirectory) }
    await runner.setInteractiveHandler { command, _, _ in
      #expect(command.first == "/usr/bin/script")
      #expect(command.contains("/dev/null"))
      #expect(command.contains("/usr/bin/ssh"))
      #expect(command.last == session.destination)
      #expect(command.contains(session.controlPath))
      try Data().write(to: URL(fileURLWithPath: session.controlPath))
    }
    await runner.setCaptureHandler { command, _, _ in
      if command.contains("-O") {
        #expect(command.contains("exit"))
        #expect(command.contains(session.controlPath))
        return ""
      }
      let separator = try #require(command.firstIndex(of: "--"))
      #expect(command[separator + 1] == session.destination)
      #expect(command.contains(session.controlPath))
      #expect(command.contains("BatchMode=yes"))
      #expect(command.last?.contains("__device-source") == true)
      return String(decoding: fixture.snapshotData, as: UTF8.self)
    }

    try await session.connect()
    try await session.deploy(bundle: fixture.bundle)
    let snapshot = try await session.snapshot()
    try await session.cleanup()

    let input = try #require(await runner.inputCommandSnapshot().first)
    #expect(input.input == fixture.bundleData)
    let separator = try #require(input.command.firstIndex(of: "--"))
    #expect(input.command[separator + 1] == session.destination)
    #expect(input.command.contains(session.controlPath))
    #expect(input.command.contains("BatchMode=yes"))
    #expect(input.command.last?.contains("tar -xf - -C") == true)
    #expect(input.env == nil)
    #expect(snapshot.version == "26.0.1")
    #expect(snapshot.build == "23A355")
    #expect(snapshot.architecture == "cpu16777228-sub2")
    let cleanup = try #require(await runner.simpleCommandSnapshot().last)
    #expect(cleanup.command.last?.contains("uncollected helper attempt remains") == true)
    #expect(cleanup.command.last?.contains(session.directory) == true)
    #expect(await runner.streamingCommandSnapshot().isEmpty)
    #expect(await runner.interactiveCommandSnapshot().count == 1)
    #expect(!FileManager.default.fileExists(atPath: session.controlDirectory.path))
  }

  @Test(arguments: [false, true])
  func cleanupStopsTheOwnedMasterAfterRemoteFailureAndRetainsAFailedSocket(masterFails: Bool) async throws {
    let runner = RecordingCommandRunner()
    let session = PrivateHeaderKitSSHSession(destination: "iphone-se", processRunner: runner)
    defer { try? FileManager.default.removeItem(at: session.controlDirectory) }
    await runner.setInteractiveHandler { _, _, _ in
      try Data().write(to: URL(fileURLWithPath: session.controlPath))
    }
    await runner.setSimpleHandler { _, _, _ in
      throw ToolingError.message("uncollected fixture attempt remains")
    }
    await runner.setCaptureHandler { command, _, _ in
      #expect(command.contains("-O"))
      #expect(command.contains("exit"))
      #expect(command.contains(session.controlPath))
      if masterFails { throw ToolingError.message("fixture master shutdown failed") }
      return ""
    }
    try await session.connect()

    do {
      try await session.cleanup()
      Issue.record("remote cleanup failure unexpectedly succeeded")
    } catch {
      let message = String(describing: error)
      #expect(message.contains("uncollected fixture attempt remains"))
      if masterFails {
        #expect(message.contains("fixture master shutdown failed"))
        #expect(message.contains(session.controlPath))
      }
    }
    #expect(await runner.captureCommandSnapshot().count == 1)
    #expect(FileManager.default.fileExists(atPath: session.controlPath) == masterFails)
  }

  @Test func cancellingAuthenticationSkipsRemoteOperationsAndRemovesTheLocalControlDirectory() async throws {
    let runner = RecordingCommandRunner()
    let session = PrivateHeaderKitSSHSession(destination: "iphone-se", processRunner: runner)
    defer { try? FileManager.default.removeItem(at: session.controlDirectory) }
    await runner.setInteractiveHandler { command, _, _ in
      throw ToolingError.commandFailed(command: command, status: 2, stderr: "")
    }

    do {
      try await session.connect()
      Issue.record("cancelled authentication unexpectedly succeeded")
    } catch is CancellationError {}
    try await session.cleanup(removeRemoteWorkspace: false)
    #expect(!FileManager.default.fileExists(atPath: session.controlDirectory.path))
    #expect(await runner.simpleCommandSnapshot().isEmpty)
    #expect(await runner.inputCommandSnapshot().isEmpty)
  }

  @Test func sourceCollectionRejectsAnIncompatibleHelperProducer() async throws {
    let fixture = try SSHGenerationFixture()
    defer { fixture.cleanup() }
    var fields = try #require(JSONSerialization.jsonObject(with: fixture.snapshotData) as? [String: Any])
    fields["producerVersion"] = "other-producer"
    let output = String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
    let runner = RecordingCommandRunner()
    let session = PrivateHeaderKitSSHSession(destination: "iphone-se", processRunner: runner)
    await runner.setCaptureHandler { _, _, _ in output }

    do {
      _ = try await session.snapshot()
      Issue.record("an incompatible device helper was accepted")
    } catch let error as PrivateHeaderGeneration.GenerationError {
      #expect(error == .producerVersionMismatch(expected: PrivateHeaderKitBuildInfo.version, actual: "other-producer"))
    }
  }

  @Test func generationReceivesThePeerSourceAndReportsBothOperationAndCleanupFailures() async throws {
    let fixture = try SSHGenerationFixture()
    defer { fixture.cleanup() }
    let runner = RecordingCommandRunner()
    await fixture.stubDeployment(using: runner)
    await runner.setSimpleHandler { command, _, _ in
      if command.first == "tar" {
        try fixture.bundleData.write(to: URL(fileURLWithPath: command[2]))
      } else {
        throw ToolingError.message("SSH unavailable during cleanup")
      }
    }
    let client = PrivateHeaderKitGenerationClient(prepare: { request in
      #expect(request.source.version == "26.0.1")
      #expect(request.source.build == "23A355")
      #expect(request.source.artifactPlatformDirectoryName == "iPhoneOS")
      #expect(request.options.deviceSource?.cacheUUID == fixture.cacheUUID)
      #expect(request.options.targetRequest == .query("SpringBoard"))
      #expect(request.options.rawDumpingOptions.useSharedCache)
      throw ToolingError.message("fixture preparation failed")
    })
    do {
      _ = try await runPrivateHeaderKitSSHGenerateCommand(
        .init(destination: "iphone-se", outputBaseDirectory: fixture.output.path, targetQuery: "SpringBoard", continuationMode: nil),
        currentExecutableURL: fixture.executable, processRunner: runner, generationClient: client,
        outputLogger: { _ in }, errorLogger: { _ in }
      )
      Issue.record("a failed SSH run unexpectedly succeeded")
    } catch let error as PrivateHeaderKitSSHCleanupFailure {
      #expect(error.description.contains("fixture preparation failed"))
      #expect(error.description.contains("SSH unavailable during cleanup"))
      #expect(error.description.contains(error.remoteDirectory))
    }
  }

  @Test func receiverRejectingFileInputReportsItsFailureAndStillCleansUpTheSSHSession() async throws {
    let fixture = try SSHGenerationFixture()
    defer { fixture.cleanup() }
    let receiverInput = fixture.root.appendingPathComponent("receiver-input.bin")
    try Data(repeating: 0xa5, count: 2 * 1_024 * 1_024).write(to: receiverInput)
    let runner = RecordingCommandRunner()
    await fixture.stubDeployment(using: runner)
    await runner.setInteractiveHandler { command, _, _ in
      let index = try #require(command.firstIndex(of: "-S"))
      try Data().write(to: URL(fileURLWithPath: command[index + 1]))
    }
    await runner.setInputHandler { _, _, _, _ in
      try await ProcessRunner().runWithInputFile(
        ["/bin/sh", "-c", "printf 'receiver rejected' >&2; exit 17"],
        inputFile: receiverInput, env: nil, cwd: nil
      )
    }
    await runner.setCaptureHandler { command, _, _ in
      #expect(command.contains("-O"))
      #expect(command.contains("exit"))
      return ""
    }
    let errors = SSHTestMessages()

    let status = await runPrivateHeaderKitCommand(
      ["privateheaderkit", "--ssh", "iphone-se", "--out", fixture.output.path, "--target", "SpringBoard"],
      currentExecutableURL: fixture.executable,
      generationClient: .init(prepare: { _ in
        Issue.record("rejected deployment unexpectedly prepared generation")
        throw ToolingError.message("unexpected generation")
      }),
      sshProcessRunner: runner, outputLogger: { _ in }, errorLogger: errors.append
    )

    #expect(status == 2)
    #expect(errors.text.contains("status=17"))
    #expect(errors.text.contains("receiver rejected"))
    let cleanupCommands = await runner.simpleCommandSnapshot().filter { $0.command.first == "ssh" }
    #expect(cleanupCommands.count == 1)
    #expect(cleanupCommands.first?.command.last?.contains("rm -rf") == true)
    #expect(await runner.captureCommandSnapshot().count == 1)
    let authentication = try #require(await runner.interactiveCommandSnapshot().first)
    let index = try #require(authentication.command.firstIndex(of: "-S"))
    let controlDirectory = URL(fileURLWithPath: authentication.command[index + 1]).deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: controlDirectory) }
    #expect(!FileManager.default.fileExists(atPath: controlDirectory.path))
  }

  @Test(arguments: [Int32(0), Int32(1)])
  func rawDumpRecoversHeadersAndReportsBeforeRemovingTheRemoteAttempt(status: Int32) async throws {
    let fixture = try SSHGenerationFixture()
    defer { fixture.cleanup() }
    let invocation = try fixture.invocation()
    let runner = RecordingCommandRunner()
    await runner.setStreamingHandler { command, _, _ in
      #expect(command == invocation.command)
      return .init(status: status, wasKilled: false, lastLines: status == 0 ? [] : ["fixture dump failure"])
    }
    await runner.setCaptureChunksHandler { _, _, _, consume in
      try await consume(Data([0, 0xff, 1]))
      try await consume(Data([2, 3]))
    }
    await runner.setSimpleHandler { command, _, _ in
      if command.first == "tar" {
        let recovery = URL(fileURLWithPath: command[4])
        #expect(try Data(contentsOf: URL(fileURLWithPath: command[2])) == Data([0, 0xff, 1, 2, 3]))
        try fixture.writeRecoveredAttempt(invocation, to: recovery)
      }
    }

    let result = try await runPrivateHeaderKitRawDump(invocation, processRunner: runner, recoveryReporter: { _ in })
    #expect(result.terminationStatus == status)
    #expect((result.failureSummary?.contains("fixture dump failure") ?? false) == (status != 0))
    #expect(try String(contentsOf: invocation.stagingOutputDirectory.appendingPathComponent("Generated.h"), encoding: .utf8) == "// device fixture\n")
    #expect(!FileManager.default.fileExists(atPath: invocation.processHandshakeReportURL.path))
    #expect(!FileManager.default.fileExists(atPath: invocation.diagnosticsReportURL.path))
    let commands = await runner.simpleCommandSnapshot().map(\.command)
    #expect(commands.count == 3)
    #expect(commands.last?.last?.contains("rm -rf") == true)
    #expect(commands.last?.last?.contains(try #require(invocation.remoteAttemptDirectory)) == true)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).allSatisfy { !$0.hasPrefix(".ssh-recovery-") })
  }

  @Test func disconnectedRecoveryKeepsTheRemoteAttemptAndLocalArchive() async throws {
    let fixture = try SSHGenerationFixture()
    defer { fixture.cleanup() }
    let invocation = try fixture.invocation()
    let runner = RecordingCommandRunner()
    await runner.setStreamingHandler { _, _, _ in
      .init(status: 255, wasKilled: false, lastLines: ["connection lost"])
    }
    await runner.setCaptureChunksHandler { _, _, _, consume in
      try await consume(Data("partial archive".utf8))
      throw ToolingError.message("archive transfer disconnected")
    }

    do {
      _ = try await runPrivateHeaderKitSSHRawDumpAttempt(invocation, processRunner: runner)
      Issue.record("failed recovery unexpectedly succeeded")
    } catch {
      let message = String(describing: error)
      #expect(message.contains("SSH helper finished with status 255"))
      #expect(message.contains("archive transfer disconnected"))
      #expect(message.contains(try #require(invocation.remoteAttemptDirectory)))
    }
    let archive = fixture.root.appendingPathComponent(".ssh-recovery-" + invocation.processHandshakeID.uuidString + ".tar")
    #expect(try Data(contentsOf: archive) == Data("partial archive".utf8))
    #expect(await runner.simpleCommandSnapshot().allSatisfy { $0.command.last?.contains("rm -rf") != true })
  }
}

private struct SSHGenerationFixture: Sendable {
  let root: URL
  let snapshotData: Data
  let bundleData = Data([0, 0xff, 10, 13, 0x80])
  let cacheUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("SSHGenerationTests-" + UUID().uuidString)
    let systemRoot = root.appendingPathComponent("Peer")
    let versionURL = systemRoot.appendingPathComponent("System/Library/CoreServices/SystemVersion.plist")
    try FileManager.default.createDirectory(at: versionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PropertyListSerialization.data(
      fromPropertyList: ["ProductVersion": "26.0.1", "ProductBuildVersion": "23A355"], format: .binary, options: 0
    ).write(to: versionURL)
    snapshotData = try JSONEncoder().encode(PrivateHeaderGeneration.DeviceSourceSnapshot.collect(
      systemRoot: systemRoot, architecture: "cpu16777228-sub2",
      inventory: .init(cacheUUID: cacheUUID, imagePaths: ["/usr/lib/libobjc.A.dylib"])
    ))
    try bundleData.write(to: root.appendingPathComponent("helper.tar"))
    let helper = root.appendingPathComponent("privateheaderkit-device-helper")
    try Data().write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
  }

  var bundle: URL { root.appendingPathComponent("helper.tar") }
  var executable: URL { root.appendingPathComponent("privateheaderkit") }
  var output: URL { root.appendingPathComponent("Output") }

  func stubDeployment(using runner: RecordingCommandRunner) async {
    await runner.setCaptureHandler { _, _, _ in String(decoding: snapshotData, as: UTF8.self) }
    await runner.setSimpleHandler { command, _, _ in
      if command.first == "tar" { try bundleData.write(to: URL(fileURLWithPath: command[2])) }
    }
  }

  func invocation() throws -> PrivateHeaderGeneration.RawDumping.Invocation {
    let staging = root.appendingPathComponent("stage")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let helper = root.appendingPathComponent("privateheaderkit-device-helper")
    return PrivateHeaderGeneration.RawDumping.makeInvocation(try .init(
      helperURLs: .init(host: helper, simulator: helper),
      executionMode: .ssh(destination: "iphone-se", directory: "/tmp/privateheaderkit-fixture"),
      inputPath: "/System/Library/PrivateFrameworks/SpringBoard.framework",
      stagingOutputDirectory: staging
    ))
  }

  func writeRecoveredAttempt(_ invocation: PrivateHeaderGeneration.RawDumping.Invocation, to recovery: URL) throws {
    let stage = recovery.appendingPathComponent(invocation.stagingOutputDirectory.lastPathComponent)
    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
    try Data("// device fixture\n".utf8).write(to: stage.appendingPathComponent("Generated.h"))
    let handshake = try PrivateHeaderKitRawDumpProcessHandshake(
      invocationID: invocation.processHandshakeID, processIdentifier: 4242,
      helperStartedAtUnixMicroseconds: 1_700_000_000_123_456,
      executableName: "privateheaderkit-device-helper",
      executableMachOUUID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    )
    try handshake.encoded().write(to: recovery.appendingPathComponent(invocation.processHandshakeReportURL.lastPathComponent))
    try JSONEncoder().encode(PrivateHeaderKitRawDumpDiagnosticsReport(diagnostics: []))
      .write(to: recovery.appendingPathComponent(invocation.diagnosticsReportURL.lastPathComponent))
  }

  func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private final class SSHTestMessages: @unchecked Sendable {
  private let lock = NSLock()
  private var messages: [String] = []

  func append(_ message: String) {
    lock.lock()
    defer { lock.unlock() }
    messages.append(message)
  }

  var text: String {
    lock.lock()
    defer { lock.unlock() }
    return messages.joined(separator: "\n")
  }
}
