import Foundation
import PrivateHeaderKitHelperProtocol

#if canImport(Darwin)
import Darwin
import MachO

extension PrivateHeaderGeneration {
    package struct RunningApplicationResolver {
        struct Process {
            let identifier: Int32
            let executableNamePrefix: Data
        }

        private struct ApplicationInfo: Decodable {
            let bundleIdentifier: String
            let executableName: String
            let version: String?
            let build: String?

            enum CodingKeys: String, CodingKey {
                case bundleIdentifier = "CFBundleIdentifier"
                case executableName = "CFBundleExecutable"
                case version = "CFBundleShortVersionString"
                case build = "CFBundleVersion"
            }
        }

        enum Selector {
            case bundleIdentifier(String)
            case processIdentifier(Int32)
        }

        private let processProvider: () throws -> [Process]
        private let bundleProvider: () throws -> (bundles: [URL], failures: [String])
        private let fileReader: (URL) throws -> Data
        private let imageInventory: (Int32) throws -> PrivateHeaderKitProcessImageInventory

        init(
            processProvider: @escaping () throws -> [Process] = Self.runningProcesses,
            bundleProvider: @escaping () throws -> (bundles: [URL], failures: [String]) = Self.installedBundles,
            fileReader: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) },
            imageInventory: @escaping (Int32) throws -> PrivateHeaderKitProcessImageInventory
        ) {
            self.processProvider = processProvider
            self.bundleProvider = bundleProvider
            self.fileReader = fileReader
            self.imageInventory = imageInventory
        }

        package static func resolve(
            arguments: [String],
            imageInventory: @escaping (Int32) throws -> PrivateHeaderKitProcessImageInventory
        ) throws -> PrivateHeaderKitRunningApplicationReport {
            guard arguments.count == 3, arguments[0] == PrivateHeaderKitHelperCommand.runningApplication.rawValue else {
                throw ResolutionError.invalidArguments
            }
            let selector: Selector
            switch arguments[1] {
            case "--app" where !arguments[2].isEmpty:
                selector = .bundleIdentifier(arguments[2])
            case "--pid":
                guard let pid = Int32(arguments[2]), pid > 0 else { throw ResolutionError.invalidArguments }
                selector = .processIdentifier(pid)
            default:
                throw ResolutionError.invalidArguments
            }
            return try Self(imageInventory: imageInventory).resolve(selector)
        }

        func resolve(_ selector: Selector) throws -> PrivateHeaderKitRunningApplicationReport {
            switch selector {
            case .processIdentifier(let pid):
                let image = try mainImage(in: imageInventory(pid), expectedPID: pid)
                let executable = URL(filePath: image.path)
                let bundle = executable.deletingLastPathComponent()
                guard bundle.pathExtension == "app" else {
                    throw ResolutionError.notApplicationProcess(pid)
                }
                let info = try applicationInfo(at: bundle)
                guard try isMainExecutable(image, in: bundle, info: info) else {
                    throw ResolutionError.notApplicationProcess(pid)
                }
                return try report(pid: pid, info: info, image: image)
            case .bundleIdentifier(let identifier):
                let discovery = try bundleProvider()
                var metadataFailures = discovery.failures
                var matchingBundles: [(URL, ApplicationInfo)] = []
                for bundle in discovery.bundles {
                    do {
                        let info = try applicationInfo(at: bundle)
                        if info.bundleIdentifier == identifier { matchingBundles.append((bundle, info)) }
                    } catch {
                        metadataFailures.append("\(bundle.path): \(error)")
                    }
                }
                guard !matchingBundles.isEmpty else {
                    if !metadataFailures.isEmpty {
                        throw ResolutionError.bundleMetadataUnavailable(identifier, metadataFailures.sorted())
                    }
                    throw ResolutionError.applicationNotInstalled(identifier)
                }
                let processes = try processProvider().sorted { $0.identifier < $1.identifier }
                var applications: [PrivateHeaderKitRunningApplicationReport] = []
                var processFailures: [String] = []
                for process in processes where matchingBundles.contains(where: {
                    let bytes = Data($0.1.executableName.utf8)
                    return bytes == process.executableNamePrefix
                        || (process.executableNamePrefix.count == Int(MAXCOMLEN)
                            && bytes.starts(with: process.executableNamePrefix))
                }) {
                    do {
                        let image = try mainImage(in: imageInventory(process.identifier), expectedPID: process.identifier)
                        for (bundle, info) in matchingBundles where try isMainExecutable(image, in: bundle, info: info) {
                            applications.append(try report(pid: process.identifier, info: info, image: image))
                            break
                        }
                    } catch {
                        processFailures.append("PID \(process.identifier): \(error)")
                    }
                }
                guard processFailures.isEmpty else {
                    throw ResolutionError.processInspectionFailed(processFailures)
                }
                guard !applications.isEmpty else { throw ResolutionError.applicationNotRunning(identifier) }
                guard applications.count == 1 else {
                    throw ResolutionError.multipleApplicationProcesses(identifier, applications.map { $0.application.processIdentifier })
                }
                return applications[0]
            }
        }

        private func applicationInfo(at bundle: URL) throws -> ApplicationInfo {
            let info = try PropertyListDecoder().decode(
                ApplicationInfo.self, from: fileReader(bundle.appending(path: "Info.plist"))
            )
            guard !info.bundleIdentifier.isEmpty, !info.executableName.isEmpty,
                  info.executableName != ".", info.executableName != "..", !info.executableName.contains("/") else {
                throw ResolutionError.invalidBundleMetadata(bundle.path)
            }
            return info
        }

        private func mainImage(in inventory: PrivateHeaderKitProcessImageInventory, expectedPID: Int32) throws -> PrivateHeaderKitProcessImage {
            guard inventory.processIdentifier == expectedPID else { throw ResolutionError.processIdentityMismatch }
            let mainImages = inventory.images.filter { $0.fileType == UInt32(MH_EXECUTE) }
            guard mainImages.count == 1, let image = mainImages.first else {
                throw ResolutionError.mainExecutableUnavailable(expectedPID, inventory.failures.map(\.error))
            }
            return image
        }

        private func isMainExecutable(_ image: PrivateHeaderKitProcessImage, in bundle: URL, info: ApplicationInfo) throws -> Bool {
            let executable = URL(filePath: image.path)
            var relationship = FileManager.URLRelationship.other
            try FileManager.default.getRelationship(&relationship, ofDirectoryAt: bundle, toItemAt: executable)
            guard relationship == .contains else { return false }
            return executable.resolvingSymlinksInPath()
                == bundle.appending(path: info.executableName).resolvingSymlinksInPath()
        }

        private func report(pid: Int32, info: ApplicationInfo, image: PrivateHeaderKitProcessImage) throws -> PrivateHeaderKitRunningApplicationReport {
            try .init(application: .init(
                processIdentifier: pid, bundleIdentifier: info.bundleIdentifier, version: info.version,
                build: info.build, executableName: info.executableName, mainImage: image
            ))
        }

        static func runningProcesses() throws -> [Process] {
            var mib = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { throw currentPOSIXError() }
            // The process table can grow between the size query and the read.
            // ENOMEM means that exact race; query its new size rather than truncating it.
            while true {
                var bytes = Data(count: size)
                var actual = size
                let status = bytes.withUnsafeMutableBytes {
                    sysctl(&mib, u_int(mib.count), $0.baseAddress, &actual, nil, 0)
                }
                if status != 0 {
                    guard errno == ENOMEM else { throw currentPOSIXError() }
                    guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { throw currentPOSIXError() }
                    continue
                }
                let recordSize = MemoryLayout<kinfo_proc>.size
                guard actual <= bytes.count, actual.isMultiple(of: recordSize) else {
                    throw ResolutionError.invalidProcessTable
                }
                return (0..<actual / recordSize).compactMap { index in
                    var record = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: index * recordSize, as: kinfo_proc.self) }
                    guard record.kp_proc.p_pid > 0 else { return nil }
                    let name = withUnsafeBytes(of: &record.kp_proc.p_comm) { bytes -> Data in
                        let end = bytes.firstIndex(of: 0) ?? bytes.count
                        return Data(bytes[..<end])
                    }
                    return Process(identifier: record.kp_proc.p_pid, executableNamePrefix: name)
                }
            }
        }

        static func installedBundles() throws -> (bundles: [URL], failures: [String]) {
            let fileManager = FileManager.default
            var bundles: [URL] = []
            var failures: [String] = []
            for root in [URL(filePath: "/var/containers/Bundle/Application"), URL(filePath: "/Applications")] {
                do {
                    let entries = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
                    for entry in entries {
                        if entry.pathExtension == "app" { bundles.append(entry) }
                        else if root.lastPathComponent == "Application", try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                            do {
                                bundles.append(contentsOf: try fileManager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)
                                    .filter { $0.pathExtension == "app" })
                            } catch { failures.append("\(entry.path): \(error)") }
                        }
                    }
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                    continue
                } catch { failures.append("\(root.path): \(error)") }
            }
            return (Array(Set(bundles)).sorted { $0.path < $1.path }, failures)
        }

        private static func currentPOSIXError() -> POSIXError {
            POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        enum ResolutionError: Error, Equatable, CustomStringConvertible {
            case invalidArguments
            case invalidProcessTable
            case invalidBundleMetadata(String)
            case processIdentityMismatch
            case notApplicationProcess(Int32)
            case mainExecutableUnavailable(Int32, [String])
            case applicationNotInstalled(String)
            case applicationNotRunning(String)
            case bundleMetadataUnavailable(String, [String])
            case processInspectionFailed([String])
            case multipleApplicationProcesses(String, [Int32])

            var description: String {
                switch self {
                case .invalidArguments: "expected __running-application --app <bundle-identifier> or __running-application --pid <positive-pid>"
                case .invalidProcessTable: "kernel returned a truncated process table"
                case .invalidBundleMetadata(let path): "invalid application bundle metadata: \(path)"
                case .processIdentityMismatch: "process inventory belongs to a different PID"
                case .notApplicationProcess(let pid): "PID \(pid) is not the main executable of an application bundle"
                case .mainExecutableUnavailable(let pid, let failures): "main executable could not be inspected for PID \(pid): \(failures.joined(separator: "; "))"
                case .applicationNotInstalled(let identifier): "application is not installed: \(identifier)"
                case .applicationNotRunning(let identifier): "application is not running: \(identifier); launch it before generation"
                case .bundleMetadataUnavailable(let identifier, let failures): "could not locate application \(identifier); bundle metadata inspection failed: \(failures.joined(separator: "; "))"
                case .processInspectionFailed(let failures): "candidate application process inspection failed: \(failures.joined(separator: "; "))"
                case .multipleApplicationProcesses(let identifier, let pids): "application \(identifier) has multiple processes (\(pids.map(String.init).joined(separator: ", "))); select one with --pid"
                }
            }
        }
    }
}
#endif
