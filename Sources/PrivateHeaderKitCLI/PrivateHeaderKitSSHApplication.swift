import Foundation
import PrivateHeaderKitCore
import PrivateHeaderKitHelperProtocol
import PrivateHeaderKitTooling

extension PrivateHeaderKitSSHSession {
  func recoverApplication(
    _ selection: PrivateHeaderKitSSHGenerateCommand.ApplicationSelection,
    localDirectory: URL,
    includesBinary: Bool
  ) async throws -> (snapshot: PrivateHeaderGeneration.ApplicationSourceSnapshot, systemVersion: PrivateHeaderKitOperatingSystemVersion) {
    let q = PrivateHeaderGeneration.RawDumping.shellQuote
    let helper = q(directory + "/privateheaderkit-device-helper")
    let selector: String
    switch selection {
    case .bundleIdentifier(let identifier): selector = "--app " + q(identifier)
    case .processIdentifier(let identifier): selector = "--pid " + String(identifier)
    }
    let applicationReport: PrivateHeaderKitRunningApplicationReport = try await captureReport(
      helper + " " + PrivateHeaderKitHelperCommand.runningApplication.rawValue + " " + selector
    )
    try requireProducer(applicationReport.producerVersion)
    guard let systemVersion = applicationReport.systemVersion else {
      throw ToolingError.message("running application report did not identify the source OS")
    }
    let application = applicationReport.application
    switch selection {
    case .bundleIdentifier(let identifier):
      guard application.bundleIdentifier == identifier else { throw ToolingError.message("application selection changed before recovery") }
    case .processIdentifier(let identifier):
      guard application.processIdentifier == identifier else { throw ToolingError.message("application process selection changed before recovery") }
    }
    let image = application.mainImage
    guard image.fileType == 2 else { throw ToolingError.message("selected application has no main executable image") }
    let identity = try PrivateHeaderGeneration.ApplicationIdentity(
      bundleIdentifier: application.bundleIdentifier, version: application.version, build: application.build,
      image: image
    )
    let inputDirectory = directory + "/application-input"
    let binaryPath = inputDirectory + "/Executable"
    try await processRunner.runSimple(command("mkdir -m 700 " + q(inputDirectory)), env: nil, cwd: nil)
    let pidFile = inputDirectory + "/helper.pid"
    let recovery = helper + " " + PrivateHeaderKitHelperCommand.recoverProcessImage.rawValue
      + " --pid " + String(application.processIdentifier)
      + " --image-address " + String(image.loadAddress)
      + " --expected-uuid " + q(image.uuid.uuidString.lowercased())
      + " --output " + q(binaryPath)
    let script = recovery + " & pid=$!; printf '%s\\n' \"$pid\" > " + q(pidFile) + "; "
      + "trap 'kill \"$pid\" 2>/dev/null; wait \"$pid\"; exit 130' HUP INT TERM; "
      + "wait \"$pid\"; status=$?; rm -f " + q(pidFile) + "; trap - HUP INT TERM; exit \"$status\""
    let outcome: Result<PrivateHeaderKitRecoveredProcessImage, any Error>
    do { outcome = .success(try await captureReport(script)) }
    catch { outcome = .failure(error) }
    do {
      try await Task.detached {
        try await terminatePrivateHeaderKitOwnedSSHProcess(
          destination: destination, controlPath: controlPath, pidFile: pidFile,
          identifier: binaryPath, processRunner: processRunner
        )
      }.value
    } catch {
      let primary: String
      switch outcome {
      case .success: primary = "application image recovery finished"
      case .failure(let failure): primary = String(describing: failure)
      }
      throw ToolingError.message(primary + "; owned recovery helper cleanup failed: \(error); remaining workspace: \(inputDirectory)")
    }
    let recovered = try outcome.get()
    try requireProducer(recovered.producerVersion)
    guard recovered.processIdentifier == application.processIdentifier,
      recovered.image == image, recovered.outputPath == binaryPath
    else { throw ToolingError.message("recovered application image no longer matches the selected process image") }
    var localBinary: URL?
    if includesBinary {
      let destinationURL = localDirectory.appendingPathComponent("Executable.macho")
      try await receiveFile(binaryPath, at: destinationURL)
      localBinary = destinationURL
    }
    return (.init(identity: identity, recoveredBinaryPath: binaryPath, localBinaryURL: localBinary), systemVersion)
  }

  private func captureReport<Report: Decodable>(_ script: String) async throws -> Report {
    let text = try await processRunner.runCapture(command(script), env: nil, cwd: nil)
    return try JSONDecoder().decode(Report.self, from: Data(text.utf8))
  }

  private func requireProducer(_ version: String) throws {
    guard version == PrivateHeaderKitBuildInfo.version else {
      throw PrivateHeaderGeneration.GenerationError.producerVersionMismatch(expected: PrivateHeaderKitBuildInfo.version, actual: version)
    }
  }

  private func receiveFile(_ path: String, at destination: URL) async throws {
    guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
      throw CocoaError(.fileWriteUnknown)
    }
    let handle = try FileHandle(forWritingTo: destination)
    do {
      try await processRunner.runCaptureChunks(
        command("cat " + PrivateHeaderGeneration.RawDumping.shellQuote(path)), env: nil, cwd: nil,
        consumeStandardOutput: { data in try handle.write(contentsOf: data) }
      )
    } catch {
      let primary = error
      do { try handle.close() }
      catch { throw ToolingError.message("\(primary); analysis binary close also failed: \(error)") }
      throw primary
    }
    try handle.close()
  }
}

func terminatePrivateHeaderKitOwnedSSHProcess(
  destination: String, controlPath: String?, pidFile: String,
  identifier: String, processRunner: any CommandRunning
) async throws {
  let q = PrivateHeaderGeneration.RawDumping.shellQuote
  let script = "if [ -f " + q(pidFile) + " ]; then pid=$(cat " + q(pidFile) + "); "
    + "case \"$pid\" in ''|*[!0-9]*) echo 'invalid owned helper PID' >&2; exit 1;; esac; "
    + "if ! [ \"$pid\" -gt 0 ]; then echo 'invalid owned helper PID' >&2; exit 1; fi; "
    + "args=$(ps -ww -p \"$pid\" -o command=); "
    + "case \"$args\" in *" + q(identifier)
    + "*) kill -KILL \"$pid\"; while ps -ww -p \"$pid\" -o command= | grep -F "
    + q(identifier)
    + " >/dev/null; do sleep 0.1; done;; '') :;; *) echo 'owned helper PID no longer matches invocation' >&2; exit 1;; esac; fi; rm -f " + q(pidFile)
  try await processRunner.runSimple(
    PrivateHeaderGeneration.RawDumping.sshCommand(destination: destination, script: script, controlPath: controlPath),
    env: nil, cwd: nil
  )
}
