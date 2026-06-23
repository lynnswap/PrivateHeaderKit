import PrivateHeaderKitRawDumpCore

@main
struct PrivateHeaderKitSimulatorHelperMain {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "__raw-dump" {
            arguments.removeFirst()
        }
        await PrivateHeaderKitRawDumpCLI.main(arguments: arguments)
    }
}
