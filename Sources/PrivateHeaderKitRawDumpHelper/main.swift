import PrivateHeaderKitHelperProtocol
import PrivateHeaderKitRawDumpCore

@main
struct PrivateHeaderKitRawDumpHelperMain {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == PrivateHeaderKitHelperCommand.rawDump.rawValue {
            arguments.removeFirst()
        }
        await PrivateHeaderKitRawDumpCLI.main(arguments: arguments)
    }
}
