import HeaderDumpCore

@main
struct HeaderDumpCLIMain {
    static func main() async {
        await HeaderDumpCore.HeaderDumpCLI.main()
    }
}
