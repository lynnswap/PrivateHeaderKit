/// The streams a command writes to: results on standard output, and diagnostics and progress
/// on standard error.
struct Console: Sendable {
    var output: PrivateHeaderKitOutputLogger
    var error: PrivateHeaderKitOutputLogger

    static let standard = Console(output: logCLIOutput, error: logCLIError)
}
