import Foundation
import PrivateHeaderKitHelperProtocol
import Testing
@testable import PrivateHeaderKitCore

#if canImport(Darwin)
@Suite struct PrivateHeaderGenerationRunningApplicationTests {
    typealias Resolver = PrivateHeaderGeneration.RunningApplicationResolver

    @Test func bundleSelectionInspectsOnlyMatchingExecutableCandidatesAndConfirmsMainPath() throws {
        let fixture = try RunningApplicationFixture()
        defer { fixture.remove() }
        let unrelated = try fixture.bundle(name: "Other", identifier: "com.example.Other")
        fixture.bundles.append(unrelated)
        fixture.processes = [fixture.process(pid: 100, name: "Sample"), fixture.process(pid: 200, name: "Other")]
        let report = try fixture.resolver().resolve(.bundleIdentifier("com.example.Sample"))
        #expect(report.application.processIdentifier == 100)
        #expect(report.application.bundleIdentifier == "com.example.Sample")
        #expect(report.application.version == "1.2.3")
        #expect(report.application.build == "45")
        #expect(fixture.inspectedPIDs == [100])
    }

    @Test func pidSelectionReadsOnlySelectedProcessAndBundleMetadata() throws {
        let fixture = try RunningApplicationFixture()
        defer { fixture.remove() }
        let report = try fixture.resolver(
            processProvider: { throw FixtureFailure.unexpected },
            bundleProvider: { throw FixtureFailure.unexpected }
        ).resolve(.processIdentifier(100))
        #expect(report.application.mainImage.uuid == fixture.uuid)
        #expect(fixture.inspectedPIDs == [100])
        #expect(fixture.readURLs == [fixture.applicationBundle.appending(path: "Info.plist")])
    }

    @Test func shorterUnrelatedProcessNameIsNotTreatedAsATruncatedMatch() throws {
        let fixture = try RunningApplicationFixture()
        defer { fixture.remove() }
        fixture.processes = [fixture.process(pid: 100, name: "Sample"), fixture.process(pid: 200, name: "Sam")]
        fixture.processFailures[200] = FixtureFailure.unreadable
        let report = try fixture.resolver().resolve(.bundleIdentifier("com.example.Sample"))
        #expect(report.application.processIdentifier == 100)
        #expect(fixture.inspectedPIDs == [100])
    }

    @Test func unreadableUnrelatedBundleMetadataDoesNotBlockConfirmedApplication() throws {
        let fixture = try RunningApplicationFixture()
        defer { fixture.remove() }
        let unreadable = fixture.directory.appending(path: "Unreadable.app")
        fixture.bundles.append(unreadable)
        fixture.unreadablePlists.insert(unreadable.appending(path: "Info.plist"))
        let report = try fixture.resolver().resolve(.bundleIdentifier("com.example.Sample"))
        #expect(report.application.processIdentifier == 100)
    }

    @Test func unreadableSelectedProcessKeepsItsUnderlyingFailure() throws {
        let fixture = try RunningApplicationFixture()
        defer { fixture.remove() }
        fixture.processFailures[100] = FixtureFailure.unreadable
        #expect(throws: Resolver.ResolutionError.processInspectionFailed(["PID 100: unreadable"])) {
            try fixture.resolver().resolve(.bundleIdentifier("com.example.Sample"))
        }
    }

    @Test func systemProcessWithMatchingShortNameDoesNotResolveAsApplication() throws {
        let fixture = try RunningApplicationFixture()
        defer { fixture.remove() }
        let systemFile = fixture.directory.appending(path: "SystemExecutable")
        try Data([0]).write(to: systemFile)
        fixture.imagePaths[100] = systemFile.path
        #expect(throws: Resolver.ResolutionError.applicationNotRunning("com.example.Sample")) {
            try fixture.resolver().resolve(.bundleIdentifier("com.example.Sample"))
        }
    }

    @Test func duplicateConfirmedApplicationProcessesRequirePidSelection() throws {
        let fixture = try RunningApplicationFixture()
        defer { fixture.remove() }
        fixture.processes = [fixture.process(pid: 101, name: "Sample"), fixture.process(pid: 100, name: "Sample")]
        #expect(throws: Resolver.ResolutionError.multipleApplicationProcesses("com.example.Sample", [100, 101])) {
            try fixture.resolver().resolve(.bundleIdentifier("com.example.Sample"))
        }
    }

    @Test func injectedDyldImageOrderDoesNotChangeMainSelection() throws {
        let fixture = try RunningApplicationFixture()
        defer { fixture.remove() }
        fixture.prependDylib = true
        let report = try fixture.resolver().resolve(.processIdentifier(100))
        #expect(report.application.mainImage.fileType == 2)
        #expect(report.application.mainImage.uuid == fixture.uuid)
    }

    @Test func inventoryPidMismatchIsRejectedBeforeBundleReads() throws {
        let fixture = try RunningApplicationFixture()
        defer { fixture.remove() }
        fixture.returnedPID = 200
        #expect(throws: Resolver.ResolutionError.processIdentityMismatch) {
            try fixture.resolver().resolve(.processIdentifier(100))
        }
        #expect(fixture.readURLs.isEmpty)
    }

    @Test func notInstalledAndNotRunningAreDifferentResults() throws {
        let fixture = try RunningApplicationFixture()
        defer { fixture.remove() }
        #expect(throws: Resolver.ResolutionError.applicationNotInstalled("com.example.Missing")) {
            try fixture.resolver().resolve(.bundleIdentifier("com.example.Missing"))
        }
        fixture.processes = []
        #expect(throws: Resolver.ResolutionError.applicationNotRunning("com.example.Sample")) {
            try fixture.resolver().resolve(.bundleIdentifier("com.example.Sample"))
        }
    }

    @Test func unreadableSelectedBundleMetadataPreservesFailureForPidSelection() throws {
        let fixture = try RunningApplicationFixture()
        defer { fixture.remove() }
        fixture.unreadablePlists.insert(fixture.applicationBundle.appending(path: "Info.plist"))
        #expect(throws: FixtureFailure.unreadable) {
            try fixture.resolver().resolve(.processIdentifier(100))
        }
    }

    @Test func truncatedProcessNameCanSelectApplicationWithLongExecutableName() throws {
        let fixture = try RunningApplicationFixture(executableName: "LongApplicationExecutable")
        defer { fixture.remove() }
        fixture.processes = [fixture.process(pid: 100, name: "LongApplicationE")]
        let report = try fixture.resolver().resolve(.bundleIdentifier("com.example.Sample"))
        #expect(report.application.executableName == "LongApplicationExecutable")
    }

    @Test(arguments: [[], ["__running-application"], ["__running-application", "--pid", "0"],
                      ["__running-application", "--app", ""], ["__running-application", "--unknown", "value"]])
    func malformedHelperArgumentsDoNotReadProcessesOrBundles(arguments: [String]) {
        #expect(throws: Resolver.ResolutionError.invalidArguments) {
            try Resolver.resolve(arguments: arguments, imageInventory: { _ in throw FixtureFailure.unexpected })
        }
    }
}

private enum FixtureFailure: Error { case unreadable, unexpected }

private final class RunningApplicationFixture {
    typealias Resolver = PrivateHeaderGeneration.RunningApplicationResolver
    let directory: URL
    let applicationBundle: URL
    let executableName: String
    let uuid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    var processes: [Resolver.Process] = []
    var bundles: [URL] = []
    var inspectedPIDs: [Int32] = []
    var readURLs: [URL] = []
    var unreadablePlists: Set<URL> = []
    var processFailures: [Int32: any Error] = [:]
    var imagePaths: [Int32: String] = [:]
    var returnedPID: Int32?
    var prependDylib = false

    init(executableName: String = "Sample") throws {
        self.executableName = executableName
        directory = URL.temporaryDirectory.appending(path: "phk-running-app-fixture-\(UUID().uuidString)")
        applicationBundle = directory.appending(path: "Sample.app")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        _ = try bundle(name: "Sample", identifier: "com.example.Sample", executable: executableName)
        bundles = [applicationBundle]
        processes = [process(pid: 100, name: String(executableName.prefix(16)))]
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func bundle(name: String, identifier: String, executable: String? = nil) throws -> URL {
        let url = directory.appending(path: "\(name).app")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let executable = executable ?? name
        try Data([0]).write(to: url.appending(path: executable))
        let plist: [String: String] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": executable,
                                       "CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "45"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: url.appending(path: "Info.plist"))
        return url
    }

    func process(pid: Int32, name: String) -> Resolver.Process {
        .init(identifier: pid, executableNamePrefix: Data(name.utf8))
    }

    func resolver(
        processProvider: (() throws -> [Resolver.Process])? = nil,
        bundleProvider: (() throws -> (bundles: [URL], failures: [String]))? = nil
    ) -> Resolver {
        Resolver(
            processProvider: processProvider ?? { self.processes },
            bundleProvider: bundleProvider ?? { (self.bundles, []) },
            fileReader: { url in
                self.readURLs.append(url)
                if self.unreadablePlists.contains(url) { throw FixtureFailure.unreadable }
                return try Data(contentsOf: url)
            },
            imageInventory: { pid in
                self.inspectedPIDs.append(pid)
                if let error = self.processFailures[pid] { throw error }
                let image = PrivateHeaderKitProcessImage(
                    loadAddress: 0x10000, path: self.imagePaths[pid] ?? self.applicationBundle.appending(path: self.executableName).path,
                    uuid: self.uuid, cpuType: 0x0100_000c, cpuSubtype: 0, fileType: 2
                )
                let hook = PrivateHeaderKitProcessImage(
                    loadAddress: 0x30000, path: "/synthetic/Hook.dylib", uuid: UUID(),
                    cpuType: 0x0100_000c, cpuSubtype: 0, fileType: 6
                )
                return try .init(processIdentifier: self.returnedPID ?? pid,
                                 images: self.prependDylib ? [hook, image] : [image], failures: [])
            }
        )
    }
}
#endif
