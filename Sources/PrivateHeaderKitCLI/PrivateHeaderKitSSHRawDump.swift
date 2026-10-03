import Foundation
import PrivateHeaderKitCore
import PrivateHeaderKitTooling

private struct SSHAttemptRecoveryFailure: Error, CustomStringConvertible, Sendable {
  let primary: String
  let failures: [String]
  let remoteDirectory: String
  let localArchive: String

  var description: String {
    primary + "; " + failures.joined(separator: "; ")
      + "; remote attempt: " + remoteDirectory + "; local recovery archive: " + localArchive
  }
}

func runPrivateHeaderKitSSHRawDumpAttempt(
  _ invocation: PrivateHeaderGeneration.RawDumping.Invocation,
  processRunner: any CommandRunning
) async throws -> StreamingCommandResult {
  guard case .ssh(let destination, _, let controlPath) = invocation.executionMode,
        let remoteAttempt = invocation.remoteAttemptDirectory else {
    throw ToolingError.invalidArgument("SSH raw dump requires an SSH execution mode")
  }
  let recoveryDirectory = URL.temporaryDirectory.appendingPathComponent(
    "privateheaderkit-ssh-recovery-" + UUID().uuidString.lowercased(), isDirectory: true
  )
  try FileManager.default.createDirectory(
    at: recoveryDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
  )
  let archive = recoveryDirectory.appendingPathComponent("partial-output.tar")
  let outcome: Result<StreamingCommandResult, any Error>
  do {
    outcome = .success(try await processRunner.runBuffered(
      invocation.command, env: invocation.environment, cwd: nil
    ))
  } catch {
    outcome = .failure(error)
  }
  let failures = await Task.detached {
    var failures: [String] = []
    let q = PrivateHeaderGeneration.RawDumping.shellQuote
    do {
      try await terminatePrivateHeaderKitOwnedSSHProcess(
        destination: destination, controlPath: controlPath, pidFile: remoteAttempt + "/pid",
        identifier: invocation.processHandshakeID.uuidString.lowercased(), processRunner: processRunner
      )
    } catch {
      failures.append("owned helper termination failed: \(error)")
    }
    do {
      try await receivePrivateHeaderKitSSHAttempt(
        invocation, destination: destination, remoteAttempt: remoteAttempt,
        archive: archive, controlPath: controlPath, processRunner: processRunner
      )
    } catch {
      failures.append("partial output/report recovery failed: \(error)")
    }
    if failures.isEmpty {
      do {
        try await processRunner.runSimple(
          PrivateHeaderGeneration.RawDumping.sshCommand(destination: destination,
            script: "rm -rf " + q(remoteAttempt), controlPath: controlPath), env: nil, cwd: nil
        )
      } catch {
        failures.append("remote attempt cleanup failed: \(error)")
      }
    }
    if failures.isEmpty {
      do { try FileManager.default.removeItem(at: recoveryDirectory) }
      catch { failures.append("local recovery cleanup failed at \(recoveryDirectory.path): \(error)") }
    }
    return failures
  }.value
  if !failures.isEmpty {
    let primary: String
    switch outcome {
    case .success(let result):
      primary = "SSH helper finished with status \(result.status)" + (result.wasKilled ? " (killed)" : "")
    case .failure(let error): primary = String(describing: error)
    }
    throw SSHAttemptRecoveryFailure(
      primary: primary, failures: failures, remoteDirectory: remoteAttempt, localArchive: archive.path
    )
  }
  return try outcome.get()
}

private func receivePrivateHeaderKitSSHAttempt(
  _ invocation: PrivateHeaderGeneration.RawDumping.Invocation,
  destination: String,
  remoteAttempt: String,
  archive: URL,
  controlPath: String?,
  processRunner: any CommandRunning
) async throws {
  let manager = FileManager.default
  guard manager.createFile(atPath: archive.path, contents: nil) else {
    throw CocoaError(.fileWriteUnknown)
  }
  let handle = try FileHandle(forWritingTo: archive)
  do {
    try await processRunner.runCaptureChunks(
      PrivateHeaderGeneration.RawDumping.sshCommand(destination: destination,
        script: "tar -cf - -C " + PrivateHeaderGeneration.RawDumping.shellQuote(remoteAttempt) + " .", controlPath: controlPath),
      env: nil, cwd: nil,
      consumeStandardOutput: { data in try handle.write(contentsOf: data) }
    )
  } catch {
    let primary = error
    do { try handle.close() }
    catch {
      throw ToolingError.message("\(primary); recovery archive close also failed: \(error)")
    }
    throw primary
  }
  try handle.close()
  let recovery = archive.deletingLastPathComponent()
    .appendingPathComponent("extracted", isDirectory: true)
  try manager.createDirectory(at: recovery, withIntermediateDirectories: false)
  try await processRunner.runSimple(["tar", "-xf", archive.path, "-C", recovery.path], env: nil, cwd: nil)
  for destinationURL in [
    invocation.stagingOutputDirectory,
    invocation.processHandshakeReportURL,
    invocation.diagnosticsReportURL,
  ] {
    let source = recovery.appendingPathComponent(destinationURL.lastPathComponent)
    if manager.fileExists(atPath: source.path) {
      if manager.fileExists(atPath: destinationURL.path) {
        try manager.removeItem(at: destinationURL)
      }
      try manager.moveItem(at: source, to: destinationURL)
    }
  }
}
