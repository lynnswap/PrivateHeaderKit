import Foundation
import PrivateHeaderKitCore
import PrivateHeaderKitHelperProtocol
import PrivateHeaderKitSourceInspection
import PrivateHeaderKitTooling

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

  func snapshot() async throws -> DeviceSourceSnapshot {
    let q = PrivateHeaderGeneration.RawDumping.shellQuote
    let output = try await processRunner.runCapture(
      command(q(directory + "/privateheaderkit-device-helper") + " "
        + PrivateHeaderKitHelperCommand.deviceSource.rawValue), env: nil, cwd: nil
    )
    let snapshot = try JSONDecoder().decode(
      DeviceSourceSnapshot.self, from: Data(output.utf8)
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
        + "if [ -f " + q(directory + "/application-input/helper.pid") + " ]; then echo 'unconfirmed application recovery helper remains' >&2; exit 1; fi; "
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

/// Generates headers from an iPhoneOS peer over SSH: the system's shared cache, or one
/// running application.
struct SSHGenerateCommand: Sendable {
  enum ApplicationSelection: Equatable, Sendable {
    case bundleIdentifier(String)
    case processIdentifier(Int32)
  }

  struct Options: Equatable, Sendable {
    let destination: String
    let outputBaseDirectory: String
    let targetQuery: String
    let continuationMode: PrivateHeaderKitContinuationMode?
    var preferRuntimeMetadata = false
    var application: ApplicationSelection? = nil
    var includesAnalysisBinary = false

    var executionOptions: PrivateHeaderGeneration.ExecutionOptions {
      switch continuationMode {
      case .resume: .init(continuation: .resume)
      case .fresh: .init(continuation: .restart)
      case nil: .init()
      }
    }
  }

  let options: Options
  /// The CLI executable, which the device helper is located from.
  let executableURL: URL
  let processRunner: any CommandRunning
  let console: Console

  func run() async throws -> Int32 {
    let helper = try await deviceHelper()
    let session = PrivateHeaderKitSSHSession(destination: options.destination, processRunner: processRunner)
    let local = URL.temporaryDirectory.appendingPathComponent("privateheaderkit-ssh-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    let bundle = local.appendingPathComponent("helper.tar")
    let helperDirectory = helper.deletingLastPathComponent()
    var inputs = [helper.lastPathComponent]
    if FileManager.default.fileExists(atPath: helperDirectory.appendingPathComponent("privateheaderkit-runtime-iphoneos").path) {
      inputs.append("privateheaderkit-runtime-iphoneos")
    }
    let outcome: Result<GenerationOutcome, any Error>
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
      let snapshot: DeviceSourceSnapshot?
      let application: PrivateHeaderGeneration.ApplicationSourceSnapshot?
      let source: PrivateHeaderGeneration.Source
      if let selection = options.application {
        let recovered = try await session.recoverApplication(selection, localDirectory: local, includesBinary: options.includesAnalysisBinary)
        application = recovered.snapshot
        snapshot = nil
        source = try .init(
          platform: .iOS, version: recovered.systemVersion.version, build: recovered.systemVersion.build,
          metadataIsSeed: recovered.systemVersion.metadataIsSeed,
          imageVariant: .iPhoneOSApplication(recovered.snapshot.identity)
        )
      } else {
        let collected = try await session.snapshot()
        snapshot = collected
        application = nil
        source = try collected.source()
      }
      let request = GenerationRequest(
        source: source,
        output: .init(baseDirectory: URL(fileURLWithPath: options.outputBaseDirectory, isDirectory: true)),
        options: .init(
          targetRequest: options.targetQuery == "all" ? .allAvailable : .query(options.targetQuery),
          systemRoot: URL(fileURLWithPath: "/", isDirectory: true),
          helperURLs: .init(
            host: helperDirectory.appendingPathComponent("privateheaderkit-raw-helper"),
            simulator: helperDirectory.appendingPathComponent("privateheaderkit-sim-helper"),
            device: helper
          ),
          executionMode: .ssh(destination: options.destination, directory: session.directory, controlPath: session.controlPath),
          rawDumpingOptions: .init(useSharedCache: application == nil, preferRuntimeMetadata: options.preferRuntimeMetadata),
          executionOptions: options.executionOptions,
          deviceSource: snapshot, applicationSource: application, includesAnalysisBinary: options.includesAnalysisBinary
        )
      )
      let prepared = try await PreparedGeneration(
        request: request, processRunner: processRunner, recoveryReporter: console.error
      )
      let result = try await prepared.runReporting(
        to: console, executionOptions: options.executionOptions,
        targetQuery: application?.identity.bundleIdentifier ?? options.targetQuery
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

  /// The device helper beside an installed CLI, or one built for iPhoneOS in a package checkout.
  private func deviceHelper() async throws -> URL {
    let executable = executableURL.resolvingSymlinksInPath()
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
}
