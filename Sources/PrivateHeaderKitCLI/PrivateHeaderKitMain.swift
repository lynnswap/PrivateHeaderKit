import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main
struct PrivateHeaderKitMain {
    static func main() async {
        exit(await runPrivateHeaderKitCommand(CommandLine.arguments))
    }
}
