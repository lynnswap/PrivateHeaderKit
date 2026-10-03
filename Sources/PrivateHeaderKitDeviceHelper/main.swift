import Foundation
import PrivateHeaderKitCore
import PrivateHeaderKitHelperProtocol
import PrivateHeaderKitRawDumpCore

@main
struct PrivateHeaderKitDeviceHelperMain {
  static func main() async {
    var arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.first == PrivateHeaderKitHelperCommand.runningApplication.rawValue {
      do {
        let report = try PrivateHeaderGeneration.RunningApplicationResolver.resolve(
          arguments: arguments,
          imageInventory: { pid in
            try LoadedProcessImages.withProcess(processIdentifier: pid) { try $0.images() }
          }
        )
        let sourceReport = try PrivateHeaderKitRunningApplicationReport(
          application: report.application, systemVersion: .collect()
        )
        let data = try JSONEncoder().encode(sourceReport)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
      } catch {
        fputs("privateheaderkit running application: error: \(error)\n", stderr)
        exit(EXIT_FAILURE)
      }
      return
    }
    if arguments.first == PrivateHeaderKitHelperCommand.processImages.rawValue
      || arguments.first == PrivateHeaderKitHelperCommand.recoverProcessImage.rawValue
    {
      do {
        let data = try LoadedProcessImageCommand.run(arguments: arguments)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
      } catch {
        fputs("privateheaderkit process image: error: \(error)\n", stderr)
        exit(EXIT_FAILURE)
      }
      return
    }
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
