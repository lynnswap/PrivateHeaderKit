import Foundation
import PrivateHeaderKitCore
import PrivateHeaderKitHelperProtocol
import PrivateHeaderKitTooling

struct PrivateHeaderKitSSHGenerateCommand: Equatable, Sendable {
  let destination: String
  let outputBaseDirectory: String
  let targetQuery: String
  let continuationMode: PrivateHeaderKitContinuationMode?
  var preferRuntimeMetadata = false

  var executionOptions: PrivateHeaderGeneration.ExecutionOptions {
    switch continuationMode {
    case .resume: .init(continuation: .resume)
    case .fresh: .init(continuation: .restart, allowsLegacyMigration: true)
    case nil: .init()
    }
  }
}

struct PrivateHeaderKitSSHSession: Sendable {
  let destination: String
  let directory: String
  let controlDirectory: URL
  let controlPath: String
  let processRunner: any CommandRunning

  init(destination: String, processRunner: any CommandRunning) {
    self.destination = destination
    let identifier = UUID().uuidString.lowercased()
    self.directory = "/tmp/privateheaderkit-" + identifier
    self.controlDirectory = URL(fileURLWithPath: "/tmp/phk-ssh-" + identifier, isDirectory: true)
    self.controlPath = controlDirectory.appendingPathComponent("master").path
    self.processRunner = processRunner
  }

  func command(_ script: String) -> [String] {
    PrivateHeaderGeneration.RawDumping.sshCommand(destination: destination, script: script, controlPath: controlPath)
  }

  func connect() async throws {
    try FileManager.default.createDirectory(
      at: controlDirectory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    do {
      // script supplies OpenSSH with its own terminal without recording the
      // conversation. The master is then owned through this unique socket.
      try await processRunner.runInteractive([
        "/usr/bin/script", "-q", "/dev/null", "/usr/bin/ssh", "-M", "-N", "-f",
        "-S", controlPath, "-o", "ControlPersist=no", "--", destination,
      ], env: nil, cwd: nil)
    } catch ToolingError.commandFailed(_, let status, _) where status == 2 {
      // macOS script returns the child's SIGINT number for Control-C.
      throw CancellationError()
    }
  }

  func deploy(bundle: URL) async throws {
    let q = PrivateHeaderGeneration.RawDumping.shellQuote
    try await processRunner.runWithInputFile(
      command("mkdir -m 700 " + q(directory) + " && tar -xf - -C " + q(directory)),
      inputFile: bundle, env: nil, cwd: nil
    )
  }

  func snapshot() async throws -> PrivateHeaderGeneration.DeviceSourceSnapshot {
    let q = PrivateHeaderGeneration.RawDumping.shellQuote
    let output = try await processRunner.runCapture(
      command(q(directory + "/privateheaderkit-device-helper") + " "
        + PrivateHeaderKitHelperCommand.deviceSource.rawValue), env: nil, cwd: nil
    )
    let snapshot = try JSONDecoder().decode(
      PrivateHeaderGeneration.DeviceSourceSnapshot.self, from: Data(output.utf8)
    )
    guard snapshot.producerVersion == PrivateHeaderKitBuildInfo.version else {
      throw PrivateHeaderGeneration.GenerationError.producerVersionMismatch(
        expected: PrivateHeaderKitBuildInfo.version, actual: snapshot.producerVersion
      )
    }
    _ = try snapshot.source()
    return snapshot
  }

  func cleanup(removeRemoteWorkspace: Bool = true) async throws {
    var failures: [String] = []
    let q = PrivateHeaderGeneration.RawDumping.shellQuote
    if removeRemoteWorkspace {
      let script = "for attempt in " + q(directory + "/runs") + "/*; do "
        + "if [ -d \"$attempt\" ]; then echo 'uncollected helper attempt remains' >&2; exit 1; fi; done; "
        + "rm -rf " + q(directory)
      do { try await processRunner.runSimple(command(script), env: nil, cwd: nil) }
      catch { failures.append(String(describing: error)) }
    }
    var masterStopped = true
    if FileManager.default.fileExists(atPath: controlPath) {
      do {
        _ = try await processRunner.runCapture([
          "ssh", "-S", controlPath, "-O", "exit", "--", destination,
        ], env: nil, cwd: nil)
      } catch {
        masterStopped = false
        failures.append("SSH master cleanup failed at \(controlPath): \(error)")
      }
    }
    if masterStopped, FileManager.default.fileExists(atPath: controlDirectory.path) {
      do { try FileManager.default.removeItem(at: controlDirectory) }
      catch { failures.append("local SSH socket cleanup failed: \(error)") }
    }
    if !failures.isEmpty { throw ToolingError.message(failures.joined(separator: "; ")) }
  }
}

struct PrivateHeaderKitSSHCleanupFailure: Error, CustomStringConvertible, Sendable {
  let primary: String
  let cleanup: String
  let remoteDirectory: String
  var remoteCleanupUnconfirmed = true

  var description: String {
    primary + "; SSH cleanup also failed: " + cleanup
      + (remoteCleanupUnconfirmed ? "; remote cleanup was not confirmed at " + remoteDirectory : "")
  }
}

func runPrivateHeaderKitSSHGenerateCommand(
  _ command: PrivateHeaderKitSSHGenerateCommand,
  currentExecutableURL: URL?,
  processRunner: any CommandRunning,
  generationClient: PrivateHeaderKitGenerationClient,
  outputLogger: @escaping PrivateHeaderKitOutputLogger,
  errorLogger: @escaping PrivateHeaderKitOutputLogger
) async throws -> Int32 {
  let helper = try await preparePrivateHeaderKitDeviceHelper(
    currentExecutableURL: currentExecutableURL, processRunner: processRunner
  )
  let session = PrivateHeaderKitSSHSession(destination: command.destination, processRunner: processRunner)
  let local = URL.temporaryDirectory.appendingPathComponent("privateheaderkit-ssh-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
  let bundle = local.appendingPathComponent("helper.tar")
  let helperDirectory = helper.deletingLastPathComponent()
  var inputs = [helper.lastPathComponent]
  if FileManager.default.fileExists(atPath: helperDirectory.appendingPathComponent("privateheaderkit-runtime-iphoneos").path) {
    inputs.append("privateheaderkit-runtime-iphoneos")
  }
  let outcome: Result<PrivateHeaderKitCommandOutcome, any Error>
  var deploymentStarted = false
  var authenticationStarted = false
  do {
    try await processRunner.runSimple(
      ["tar", "-cf", bundle.path, "-C", helperDirectory.path] + inputs, env: nil, cwd: nil
    )
    authenticationStarted = true
    try await session.connect()
    deploymentStarted = true
    try await session.deploy(bundle: bundle)
    let snapshot = try await session.snapshot()
    let request = PrivateHeaderKitGenerationRequest(
      source: try snapshot.source(),
      output: .init(baseDirectory: URL(fileURLWithPath: command.outputBaseDirectory, isDirectory: true)),
      options: .init(
        targetRequest: command.targetQuery == "all" ? .allAvailable : .query(command.targetQuery),
        systemRoot: URL(fileURLWithPath: "/", isDirectory: true),
        helperURLs: .init(
          host: helperDirectory.appendingPathComponent("privateheaderkit-raw-helper"),
          simulator: helperDirectory.appendingPathComponent("privateheaderkit-sim-helper"),
          device: helper
        ),
        executionMode: .ssh(destination: command.destination, directory: session.directory, controlPath: session.controlPath),
        rawDumpingOptions: .init(useSharedCache: true, preferRuntimeMetadata: command.preferRuntimeMetadata),
        executionOptions: command.executionOptions,
        deviceSource: snapshot
      )
    )
    let prepared = try await generationClient.prepare(request)
    let result = try await runPrivateHeaderKitPreparedGeneration(
      prepared, request: request, targetQuery: command.targetQuery,
      executionOptions: command.executionOptions, resultScreenClearer: nil,
      outputLogger: outputLogger, errorLogger: errorLogger
    )
    outcome = .success(result)
  } catch {
    outcome = .failure(error)
  }
  var cleanupFailures: [String] = []
  var remoteCleanupUnconfirmed = false
  if authenticationStarted {
    let removesRemoteWorkspace = deploymentStarted
    do {
      try await Task.detached { try await session.cleanup(removeRemoteWorkspace: removesRemoteWorkspace) }.value
    } catch {
      remoteCleanupUnconfirmed = true
      cleanupFailures.append(String(describing: error))
    }
  }
  do {
    try FileManager.default.removeItem(at: local)
  } catch {
    cleanupFailures.append("local workspace \(local.path): \(error)")
  }
  if !cleanupFailures.isEmpty {
    let primary: String
    switch outcome {
    case .success(let result):
      primary = result.failureSummary ?? "generation finished with exit code \(result.exitCode)"
    case .failure(let failure): primary = String(describing: failure)
    }
    throw PrivateHeaderKitSSHCleanupFailure(
      primary: primary, cleanup: cleanupFailures.joined(separator: "; "), remoteDirectory: session.directory,
      remoteCleanupUnconfirmed: remoteCleanupUnconfirmed
    )
  }
  return try outcome.get().exitCode
}

func preparePrivateHeaderKitDeviceHelper(
  currentExecutableURL: URL?, processRunner: any CommandRunning
) async throws -> URL {
  let executable = (currentExecutableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
    .resolvingSymlinksInPath()
  let installed = executable.deletingLastPathComponent().appendingPathComponent("privateheaderkit-device-helper")
  var root = executable.deletingLastPathComponent()
  while root.path != "/" {
    if FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
      let output = root.appendingPathComponent(".build/device-helper-distribution")
      try await processRunner.runSimple([
        "bash", root.appendingPathComponent("scripts/build-release.sh").path,
        "--version", PrivateHeaderKitBuildInfo.version, "--platform", "iphoneos",
        "--output-dir", output.path,
      ], env: nil, cwd: root)
      return output.appendingPathComponent("privateheaderkit-device-helper")
    }
    root.deleteLastPathComponent()
  }
  if FileManager.default.isExecutableFile(atPath: installed.path) { return installed }
  throw ToolingError.message("privateheaderkit-device-helper is missing; reinstall PrivateHeaderKit or build it from source")
}
