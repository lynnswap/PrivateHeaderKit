#if os(macOS)
import Foundation
import Testing

@testable import PrivateHeaderKitInstall
import PrivateHeaderKitTestSupport

@Suite
struct InstallPathGuidanceTests {
    @Test func omitsGuidanceWhenTheCommandDirectoryIsAlreadyOnPATH() throws {
        let directories = try makeTemporaryTestDirectories()
        let commandDirectory = directories.root.appendingPathComponent(
            "Private Header Bin",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: commandDirectory,
            withIntermediateDirectories: true
        )

        let messages = guidance(
            commandDirectory: commandDirectory,
            environment: ["PATH": "/usr/bin:\(commandDirectory.path):/bin"]
        )

        #expect(messages.isEmpty)
    }

    @Test func recognizesAnExistingSymlinkedPATHEntry() throws {
        let directories = try makeTemporaryTestDirectories()
        let commandDirectory = directories.root.appendingPathComponent("real-bin", isDirectory: true)
        let alias = directories.root.appendingPathComponent("bin-alias", isDirectory: true)
        try FileManager.default.createDirectory(
            at: commandDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: commandDirectory)

        let messages = guidance(
            commandDirectory: commandDirectory,
            environment: ["PATH": "/usr/bin:\(alias.path):/bin"]
        )

        #expect(messages.isEmpty)
    }

    @Test func zshGuidanceUsesZProfileAndQuotesLiteralPathsWithoutMutatingIt() throws {
        let directories = try makeTemporaryTestDirectories()
        let commandDirectory = directories.root.appendingPathComponent(
            "Private Header's Bin",
            isDirectory: true
        )
        let profile = directories.root.appendingPathComponent(".zprofile")
        let originalProfile = "export EXISTING=value\n"
        try Data(originalProfile.utf8).write(to: profile)

        let messages = guidance(
            commandDirectory: commandDirectory,
            environment: [
                "HOME": directories.root.path,
                "PATH": "/usr/bin:/bin",
                "SHELL": "/bin/zsh",
            ]
        )

        let exportLine = try #require(
            messages.first(where: { $0.hasPrefix("    export PATH=") })
        ).trimmingCharacters(in: .whitespaces)
        #expect(messages.contains("Next steps:"))
        #expect(messages.contains(where: { $0.contains(profile.path) }))
        #expect(exportLine.contains("'\\''"))
        #expect(try String(contentsOf: profile, encoding: .utf8) == originalProfile)
        #expect(try firstPATHEntry(afterRunning: exportLine) == commandDirectory.path)
    }

    @Test func zshGuidanceDoesNotAppendToAMalformedProfile() throws {
        let directories = try makeTemporaryTestDirectories()
        let profile = directories.root.appendingPathComponent(".zprofile")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)

        let messages = guidance(
            commandDirectory: directories.root.appendingPathComponent("bin", isDirectory: true),
            environment: [
                "HOME": directories.root.path,
                "PATH": "/usr/bin:/bin",
                "SHELL": "/bin/zsh",
            ]
        )

        #expect(messages.contains(where: { $0.contains("writable zsh login profile") }))
        #expect(!messages.contains(where: { $0.contains("printf '") }))
        #expect(messages.contains(where: { $0.hasPrefix("    export PATH=") }))
    }

    @Test func zshGuidanceDoesNotAppendToAReadOnlyProfile() throws {
        let directories = try makeTemporaryTestDirectories()
        let profile = directories.root.appendingPathComponent(".zprofile")
        try Data("export EXISTING=value\n".utf8).write(to: profile)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444],
            ofItemAtPath: profile.path
        )

        let messages = guidance(
            commandDirectory: directories.root.appendingPathComponent("bin", isDirectory: true),
            environment: [
                "HOME": directories.root.path,
                "PATH": "/usr/bin:/bin",
                "SHELL": "/bin/zsh",
            ]
        )

        #expect(messages.contains(where: { $0.contains("writable zsh login profile") }))
        #expect(!messages.contains(where: { $0.contains("printf '") }))
        #expect(messages.contains(where: { $0.hasPrefix("    export PATH=") }))
    }

    @Test func zshGuidanceDoesNotSuggestCreatingAProfileUnderAMissingZDotDir() throws {
        let directories = try makeTemporaryTestDirectories()
        let missingZDotDir = directories.root.appendingPathComponent("missing", isDirectory: true)

        let messages = guidance(
            commandDirectory: directories.root.appendingPathComponent("bin", isDirectory: true),
            environment: [
                "HOME": directories.root.path,
                "PATH": "/usr/bin:/bin",
                "SHELL": "/bin/zsh",
                "ZDOTDIR": missingZDotDir.path,
            ]
        )

        #expect(messages.contains(where: { $0.contains("writable zsh login profile") }))
        #expect(!messages.contains(where: { $0.contains("printf '") }))
        #expect(!messages.contains(where: { $0.contains(".zprofile") }))
    }

    @Test func zshGuidanceAcceptsAProfileSymlinkToAReadableFile() throws {
        let directories = try makeTemporaryTestDirectories()
        let realProfile = directories.root.appendingPathComponent("shared-profile")
        let profile = directories.root.appendingPathComponent(".zprofile")
        try Data().write(to: realProfile)
        try FileManager.default.createSymbolicLink(at: profile, withDestinationURL: realProfile)

        let messages = guidance(
            commandDirectory: directories.root.appendingPathComponent("bin", isDirectory: true),
            environment: [
                "HOME": directories.root.path,
                "PATH": "/usr/bin:/bin",
                "SHELL": "/bin/zsh",
            ]
        )

        #expect(messages.contains(where: { $0.contains("printf '") && $0.contains(profile.path) }))
        #expect(!messages.contains(where: { $0.contains("writable zsh login profile") }))
    }

    @Test func existingProfileEntryIsNotSuggestedAgain() throws {
        let directories = try makeTemporaryTestDirectories()
        let commandDirectory = directories.root.appendingPathComponent("bin", isDirectory: true)
        let profile = directories.root.appendingPathComponent(".zprofile")
        let exportLine = "export PATH='\(commandDirectory.path)':\"$PATH\""
        try Data("\(exportLine)\n".utf8).write(to: profile)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444],
            ofItemAtPath: profile.path
        )

        let messages = guidance(
            commandDirectory: commandDirectory,
            environment: [
                "HOME": directories.root.path,
                "PATH": "/usr/bin:/bin",
                "SHELL": "/bin/zsh",
            ]
        )

        #expect(messages.contains(where: { $0.contains("already contains the PATH entry") }))
        #expect(!messages.contains(where: { $0.contains("printf '") }))
        #expect(messages.contains("    \(exportLine)"))
    }

    @Test func bashGuidanceUsesTheFirstExistingLoginProfile() throws {
        let directories = try makeTemporaryTestDirectories()
        let bashLogin = directories.root.appendingPathComponent(".bash_login")
        let profile = directories.root.appendingPathComponent(".profile")
        try Data().write(to: bashLogin)
        try Data().write(to: profile)

        let messages = guidance(
            commandDirectory: directories.root.appendingPathComponent("bin", isDirectory: true),
            environment: [
                "HOME": directories.root.path,
                "PATH": "/usr/bin:/bin",
                "SHELL": "/opt/homebrew/bin/bash",
            ]
        )

        #expect(messages.contains(where: { $0.contains(bashLogin.path) }))
        #expect(!messages.contains(where: { $0.contains(profile.path) }))
    }

    @Test func bashGuidanceSkipsAnUnreadableLoginProfile() throws {
        let directories = try makeTemporaryTestDirectories()
        let bashProfile = directories.root.appendingPathComponent(".bash_profile")
        let bashLogin = directories.root.appendingPathComponent(".bash_login")
        try Data().write(to: bashProfile)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: bashProfile.path
        )
        try Data().write(to: bashLogin)

        let messages = guidance(
            commandDirectory: directories.root.appendingPathComponent("bin", isDirectory: true),
            environment: [
                "HOME": directories.root.path,
                "PATH": "/usr/bin:/bin",
                "SHELL": "/bin/bash",
            ]
        )

        #expect(messages.contains(where: { $0.contains(bashLogin.path) }))
        #expect(!messages.contains(where: { $0.contains(bashProfile.path) }))
    }

    @Test func bashGuidanceDoesNotAppendToMalformedProfiles() throws {
        let directories = try makeTemporaryTestDirectories()
        let bashProfile = directories.root.appendingPathComponent(".bash_profile")
        try FileManager.default.createDirectory(at: bashProfile, withIntermediateDirectories: true)

        let messages = guidance(
            commandDirectory: directories.root.appendingPathComponent("bin", isDirectory: true),
            environment: [
                "HOME": directories.root.path,
                "PATH": "/usr/bin:/bin",
                "SHELL": "/bin/bash",
            ]
        )

        #expect(messages.contains(where: { $0.contains("writable bash login profile") }))
        #expect(!messages.contains(where: { $0.contains("printf '") }))
        #expect(messages.contains(where: { $0.hasPrefix("    export PATH=") }))
    }

    @Test func unknownShellDoesNotGuessAProfileOrShellSyntax() throws {
        let directories = try makeTemporaryTestDirectories()
        let commandDirectory = directories.root.appendingPathComponent("bin", isDirectory: true)

        let messages = guidance(
            commandDirectory: commandDirectory,
            environment: [
                "HOME": directories.root.path,
                "PATH": "/usr/bin:/bin",
                "SHELL": "/usr/local/bin/fish",
            ]
        )

        #expect(messages.contains("    \(commandDirectory.path)"))
        #expect(!messages.contains(where: { $0.contains("export PATH=") }))
        #expect(!messages.contains(where: { $0.contains(".zprofile") }))
        #expect(!messages.contains(where: { $0.contains(".bash_profile") }))
    }

    @Test func unrepresentableDirectoryUsesManualGuidance() throws {
        let directories = try makeTemporaryTestDirectories()
        let commandDirectory = directories.root.appendingPathComponent("colon:bin", isDirectory: true)

        let messages = guidance(
            commandDirectory: commandDirectory,
            environment: [
                "HOME": directories.root.path,
                "PATH": "/usr/bin:/bin",
                "SHELL": "/bin/zsh",
            ]
        )

        #expect(messages.contains(where: { $0.contains("cannot be represented safely") }))
        #expect(!messages.contains(where: { $0.contains("export PATH=") }))
        #expect(!messages.contains(where: { $0.contains("printf '") }))
    }

    private func guidance(
        commandDirectory: URL,
        environment: [String: String]
    ) -> [String] {
        InstallPathGuidance(
            commandDirectory: commandDirectory,
            environment: environment,
            fileManager: .default
        ).messages()
    }

    private func firstPATHEntry(afterRunning exportLine: String) throws -> String {
        let process = Process()
        let standardOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "\(exportLine)\nprintf '%s' \"${PATH%%:*}\"",
        ]
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardOutput = standardOutput
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let data = standardOutput.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
