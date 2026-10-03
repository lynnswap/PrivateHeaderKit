import Foundation

extension PrivateHeaderGeneration.RawDumping {
  package static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  package static func sshCommand(destination: String, script: String, controlPath: String? = nil) -> [String] {
    let path = "/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:"
      + "/iosbinpack64/usr/bin:/iosbinpack64/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    var command = ["ssh", "-T"]
    if let controlPath { command += ["-S", controlPath, "-o", "ControlMaster=no", "-o", "BatchMode=yes"] }
    return command + ["--", destination,
      "sh -c " + shellQuote("export PATH=" + shellQuote(path) + "; " + script)]
  }
}

extension PrivateHeaderGeneration.RawDumping.Invocation {
  package var remoteAttemptDirectory: String? {
    guard case .ssh(_, let directory, _) = executionMode else { return nil }
    return directory + "/runs/" + processHandshakeID.uuidString.lowercased()
  }
}
