import Foundation
import PrivateHeaderKitCore
import PrivateHeaderKitHelperProtocol
import PrivateHeaderKitRawDumpCore

@main
struct PrivateHeaderKitDeviceHelperMain {
  static func main() async {
    var arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == [PrivateHeaderKitHelperCommand.deviceSource.rawValue] {
      do {
        let inventory = try PrivateHeaderKitRawDumpCLI.deviceSharedCacheInventory()
        let snapshot = try PrivateHeaderGeneration.DeviceSourceSnapshot.collect(
          architecture: PrivateHeaderKitRawDumpCLI.deviceCacheArchitecture(), inventory: inventory
        )
        let data = try JSONEncoder().encode(snapshot)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
      } catch {
        fputs("privateheaderkit __device-source: error: \(error)\n", stderr)
        exit(EXIT_FAILURE)
      }
      return
    }
    if arguments.first == PrivateHeaderKitHelperCommand.rawDump.rawValue {
      arguments.removeFirst()
    }
    await PrivateHeaderKitRawDumpCLI.main(arguments: arguments)
  }
}
