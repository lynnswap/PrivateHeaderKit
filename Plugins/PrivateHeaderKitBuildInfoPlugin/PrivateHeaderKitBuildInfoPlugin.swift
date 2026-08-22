import Foundation
import PackagePlugin

@main
struct PrivateHeaderKitBuildInfoPlugin: BuildToolPlugin {
    private static let environmentKey = "PRIVATEHEADERKIT_BUILD_VERSION"

    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard target is SourceModuleTarget else { return [] }

        let outputFile = context.pluginWorkDirectoryURL.appending(
            path: "PrivateHeaderKitBuildInfo.generated.swift"
        )
        let tool = try context.tool(named: "PrivateHeaderKitBuildInfoTool")
        var arguments = [
            "--output", outputFile.path,
            "--package-directory", context.package.directoryURL.path,
        ]
        if let environmentVersion = ProcessInfo.processInfo.environment[Self.environmentKey] {
            arguments.append(contentsOf: ["--environment-version", environmentVersion])
        } else if let gitVersion = Self.gitDescribe(in: context.package.directoryURL) {
            // Keep the Git identity in the build-command signature. Reading Git only inside the
            // tool would let SwiftPM reuse a stale generated source after HEAD changes.
            arguments.append(contentsOf: ["--environment-version", gitVersion])
        }

        return [
            .buildCommand(
                displayName: "Generate PrivateHeaderKit build info",
                executable: tool.url,
                arguments: arguments,
                outputFiles: [outputFile]
            )
        ]
    }

    private static func gitDescribe(in packageDirectory: URL) -> String? {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-C", packageDirectory.path,
            "describe", "--tags", "--always", "--dirty",
        ]
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let value = String(
            decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
