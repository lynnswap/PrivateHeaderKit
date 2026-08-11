import PrivateHeaderKitInstall

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main
struct PrivateHeaderKitInstallEntryPoint {
    static func main() {
        exit(runInstallCommand(CommandLine.arguments))
    }
}
