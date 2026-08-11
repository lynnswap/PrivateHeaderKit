import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

#if canImport(Darwin)
import Darwin
import MachO
#endif

package struct ToolArtifactInput: Equatable, Sendable {
    package let role: String
    package let url: URL

    package init(role: String, url: URL) {
        self.role = role
        self.url = url
    }
}

package struct ToolArtifactSnapshot: Equatable, Sendable {
    package let fingerprint: String
    package let artifacts: [ToolArtifactDigest]

    package var compatibilityIdentity: String {
        "phk-tool-v1:artifacts:\(fingerprint)"
    }
}

package struct ToolArtifactDigest: Codable, Equatable, Sendable {
    package let role: String
    package let sha256: String
}

package enum SwiftPMToolDestination: Equatable, Sendable {
    case host
    case simulator(sdkPath: String, triple: String)
}

package struct SwiftPMToolBuildRecipe: Equatable, Sendable {
    package let product: String
    package let configuration: String
    package let destination: SwiftPMToolDestination

    package init(
        product: String,
        configuration: String,
        destination: SwiftPMToolDestination
    ) {
        self.product = product
        self.configuration = configuration
        self.destination = destination
    }
}

package struct SwiftPMToolIdentityContext: Equatable, Sendable {
    package let repoRoot: URL
    package let runningExecutableIdentity: String
    package let builds: [SwiftPMToolBuildRecipe]
    package let externalArtifacts: [ToolArtifactInput]
    package let buildEnvironment: [String: String]

    package init(
        repoRoot: URL,
        runningExecutableIdentity: String,
        builds: [SwiftPMToolBuildRecipe],
        externalArtifacts: [ToolArtifactInput] = [],
        buildEnvironment: [String: String]
    ) {
        self.repoRoot = repoRoot
        self.runningExecutableIdentity = runningExecutableIdentity
        self.builds = builds
        self.externalArtifacts = externalArtifacts
        self.buildEnvironment = buildEnvironment
    }
}

package struct SwiftPMToolSnapshot: Equatable, Sendable {
    package let fingerprint: String

    package var compatibilityIdentity: String {
        "phk-tool-v1:swiftpm:\(fingerprint)"
    }
}

package func currentProcessExecutableBuildIdentity() throws -> String {
#if canImport(Darwin)
    guard let header = _dyld_get_image_header(0),
          header.pointee.magic == MH_MAGIC_64
    else {
        throw ToolingError.message("failed to inspect the running executable image")
    }

    var cursor = UnsafeRawPointer(header).advanced(
        by: MemoryLayout<mach_header_64>.size
    )
    var remainingBytes = Int(header.pointee.sizeofcmds)
    for _ in 0..<header.pointee.ncmds {
        guard remainingBytes >= MemoryLayout<load_command>.size else {
            break
        }
        let command = cursor.load(as: load_command.self)
        let commandSize = Int(command.cmdsize)
        guard commandSize >= MemoryLayout<load_command>.size,
              commandSize <= remainingBytes
        else {
            break
        }
        if command.cmd == LC_UUID {
            guard commandSize >= MemoryLayout<uuid_command>.size else {
                break
            }
            let uuid = cursor.load(as: uuid_command.self).uuid
            return "macho-uuid:\(UUID(uuid: uuid).uuidString.lowercased())"
        }
        cursor = cursor.advanced(by: commandSize)
        remainingBytes -= commandSize
    }
    throw ToolingError.message("the running executable has no Mach-O UUID")
#else
    throw ToolingError.message(
        "running executable identity is unavailable on this platform"
    )
#endif
}

package func captureToolArtifactSnapshot(
    runningExecutableIdentity: String,
    artifacts: [ToolArtifactInput],
    fileManager: FileManager
) throws -> ToolArtifactSnapshot {
    let records = try artifactRecords(
        artifacts,
        fileManager: fileManager
    )
    let payload = ArtifactIdentityPayload(
        schemaVersion: 1,
        runningExecutableIdentity: runningExecutableIdentity,
        artifacts: records
    )
    return ToolArtifactSnapshot(
        fingerprint: try sha256Hex(canonicalJSON(payload)),
        artifacts: records
    )
}

package func captureSwiftPMToolSnapshot(
    context: SwiftPMToolIdentityContext,
    runner: CommandRunning,
    fileManager: FileManager
) async throws -> SwiftPMToolSnapshot {
    guard !context.builds.isEmpty else {
        throw ToolingError.message("SwiftPM tool identity requires at least one build")
    }

    let descriptionOutput = try await runner.runCapture(
        ["swift", "package", "describe", "--type", "json"],
        env: nil,
        cwd: context.repoRoot
    )
    let packageDescription: DescribedPackage
    do {
        packageDescription = try JSONDecoder().decode(
            DescribedPackage.self,
            from: Data(descriptionOutput.utf8)
        )
    } catch {
        throw ToolingError.message(
            "failed to decode SwiftPM package description: \(error)"
        )
    }

    let products = Set(context.builds.map(\.product))
    let selectedTargets = try selectedTargetRecords(
        from: packageDescription,
        products: products,
        repoRoot: context.repoRoot,
        fileManager: fileManager
    )
    let manifestInputs = try manifestInputRecords(
        repoRoot: context.repoRoot,
        fileManager: fileManager
    )
    let resolvedInput = try resolvedInputRecord(
        repoRoot: context.repoRoot,
        fileManager: fileManager
    )
    let dumpOutput = try await runner.runCapture(
        ["swift", "package", "dump-package"],
        env: nil,
        cwd: context.repoRoot
    )
    let directDependencyIdentities = try directDependencyIdentities(
        from: dumpOutput,
        selectedTargetNames: Set(selectedTargets.map(\.name))
    )
    let dependencyCheckouts = try await validatedDependencyCheckouts(
        directIdentities: directDependencyIdentities,
        resolvedPins: resolvedInput.pins,
        repoRoot: context.repoRoot,
        runner: runner
    )
    let toolchain = try await toolchainRecord(
        destinations: context.builds.map(\.destination),
        environment: context.buildEnvironment,
        runner: runner,
        repoRoot: context.repoRoot
    )
    let builds = context.builds.map(BuildRecipeRecord.init).sorted {
        $0.sortKey < $1.sortKey
    }
    let externalArtifacts = try artifactRecords(
        context.externalArtifacts,
        fileManager: fileManager
    )
    let payload = SwiftPMIdentityPayload(
        schemaVersion: 1,
        runningExecutableIdentity: context.runningExecutableIdentity,
        manifestInputs: manifestInputs,
        resolvedFilePresent: resolvedInput.isPresent,
        resolvedPins: resolvedInput.pins,
        dependencyCheckouts: dependencyCheckouts,
        selectedTargets: selectedTargets,
        toolchain: toolchain,
        builds: builds,
        externalArtifacts: externalArtifacts
    )
    return SwiftPMToolSnapshot(
        fingerprint: try sha256Hex(canonicalJSON(payload))
    )
}

private struct ArtifactIdentityPayload: Encodable {
    let schemaVersion: Int
    let runningExecutableIdentity: String
    let artifacts: [ToolArtifactDigest]
}

private struct SwiftPMIdentityPayload: Encodable {
    let schemaVersion: Int
    let runningExecutableIdentity: String
    let manifestInputs: [InputRecord]
    let resolvedFilePresent: Bool
    let resolvedPins: [ResolvedPinRecord]
    let dependencyCheckouts: [DependencyCheckoutRecord]
    let selectedTargets: [SelectedTargetRecord]
    let toolchain: ToolchainRecord
    let builds: [BuildRecipeRecord]
    let externalArtifacts: [ToolArtifactDigest]
}

private struct InputRecord: Codable, Equatable {
    let path: String
    let kind: String
    let sha256: String?
    let destination: String?
}

private struct SelectedTargetRecord: Codable, Equatable {
    let name: String
    let path: String
    let products: [String]
    let inputs: [InputRecord]
}

private struct ResolvedPinRecord: Codable, Equatable {
    let identity: String
    let kind: String?
    let location: String?
    let revision: String?
    let version: String?
    let branch: String?
}

private struct DependencyCheckoutRecord: Codable, Equatable {
    let identity: String
    let revision: String
}

private struct ToolchainRecord: Codable, Equatable {
    let swiftExecutable: String
    let swiftVersion: String
    let xcodeVersion: String
    let hostTargetInfo: TargetInfoRecord
    let macOSSDKBuildVersion: String
    let simulatorTargets: [SimulatorToolchainRecord]
    let buildEnvironment: [EnvironmentRecord]
}

private struct SimulatorToolchainRecord: Codable, Equatable {
    let triple: String
    let targetInfo: TargetInfoRecord
    let sdkBuildVersion: String
}

private struct TargetInfoRecord: Codable, Equatable {
    let compilerVersion: String
    let triple: String
    let runtimeCompatibilityVersion: String?
}

private struct EnvironmentRecord: Codable, Equatable {
    let name: String
    let value: String
}

private struct BuildRecipeRecord: Codable, Equatable {
    let product: String
    let configuration: String
    let destination: String
    let triple: String?

    init(_ build: SwiftPMToolBuildRecipe) {
        product = build.product
        configuration = build.configuration
        switch build.destination {
        case .host:
            destination = "host"
            triple = nil
        case let .simulator(_, value):
            destination = "simulator"
            triple = value
        }
    }

    var sortKey: String {
        [product, configuration, destination, triple ?? ""].joined(separator: "\u{0}")
    }
}

private struct DescribedPackage: Decodable {
    let targets: [Target]

    struct Target: Decodable {
        let name: String
        let path: String
        let productMemberships: [String]?

        enum CodingKeys: String, CodingKey {
            case name
            case path
            case productMemberships = "product_memberships"
        }
    }
}

private struct ResolvedFile: Decodable {
    let pins: [Pin]

    struct Pin: Decodable {
        let identity: String
        let kind: String?
        let location: String?
        let state: State
    }

    struct State: Decodable {
        let revision: String?
        let version: String?
        let branch: String?
    }
}

private struct DumpedPackage: Decodable {
    let targets: [Target]

    struct Target: Decodable {
        let name: String
        let dependencies: [Dependency]
    }

    struct Dependency: Decodable {
        let packageIdentity: String?

        private enum CodingKeys: String, CodingKey {
            case product
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard container.contains(.product) else {
                packageIdentity = nil
                return
            }
            var product = try container.nestedUnkeyedContainer(forKey: .product)
            _ = try product.decode(String.self)
            if try product.decodeNil() {
                packageIdentity = nil
            } else {
                packageIdentity = try product.decode(String.self).lowercased()
            }
        }
    }
}

private struct DependencyGraphNode: Decodable {
    let identity: String
    let path: String
    let dependencies: [DependencyGraphNode]
}

private struct ResolvedInput {
    let isPresent: Bool
    let pins: [ResolvedPinRecord]
}

private func directDependencyIdentities(
    from output: String,
    selectedTargetNames: Set<String>
) throws -> Set<String> {
    let package: DumpedPackage
    do {
        package = try JSONDecoder().decode(
            DumpedPackage.self,
            from: Data(output.utf8)
        )
    } catch {
        throw ToolingError.message("failed to decode SwiftPM package manifest: \(error)")
    }
    let selectedTargets = package.targets.filter {
        selectedTargetNames.contains($0.name)
    }
    guard Set(selectedTargets.map(\.name)) == selectedTargetNames else {
        throw ToolingError.message(
            "SwiftPM package manifest omitted a selected helper target"
        )
    }
    return Set(selectedTargets.flatMap(\.dependencies).compactMap(\.packageIdentity))
}

private func validatedDependencyCheckouts(
    directIdentities: Set<String>,
    resolvedPins: [ResolvedPinRecord],
    repoRoot: URL,
    runner: CommandRunning
) async throws -> [DependencyCheckoutRecord] {
    guard !directIdentities.isEmpty else {
        return []
    }
    let output = try await runner.runCapture(
        [
            "swift", "package", "--force-resolved-versions",
            "show-dependencies", "--format", "json",
        ],
        env: nil,
        cwd: repoRoot
    )
    let root: DependencyGraphNode
    do {
        root = try JSONDecoder().decode(
            DependencyGraphNode.self,
            from: Data(output.utf8)
        )
    } catch {
        throw ToolingError.message("failed to decode SwiftPM dependency graph: \(error)")
    }

    var nodesByIdentity = [String: DependencyGraphNode]()
    func index(_ node: DependencyGraphNode) {
        nodesByIdentity[node.identity.lowercased()] = node
        for dependency in node.dependencies {
            index(dependency)
        }
    }
    index(root)

    var selectedIdentities = Set<String>()
    func select(_ node: DependencyGraphNode) {
        let identity = node.identity.lowercased()
        guard selectedIdentities.insert(identity).inserted else {
            return
        }
        for dependency in node.dependencies {
            select(dependency)
        }
    }
    for identity in directIdentities.sorted() {
        guard let node = nodesByIdentity[identity] else {
            throw ToolingError.message(
                "SwiftPM dependency graph omitted helper dependency \(identity)"
            )
        }
        select(node)
    }

    var pinsByIdentity = [String: ResolvedPinRecord]()
    for pin in resolvedPins {
        let identity = pin.identity.lowercased()
        guard pinsByIdentity.updateValue(pin, forKey: identity) == nil else {
            throw ToolingError.message(
                "Package.resolved contains duplicate identity \(identity)"
            )
        }
    }
    var records = [DependencyCheckoutRecord]()
    for identity in selectedIdentities.sorted() {
        guard let node = nodesByIdentity[identity],
              let pin = pinsByIdentity[identity],
              let revision = pin.revision?.lowercased(),
              revision.range(
                of: #"^[0-9a-f]{40}$"#,
                options: .regularExpression
              ) != nil
        else {
            throw ToolingError.message(
                "helper dependency \(identity) is not pinned to a Git revision"
            )
        }
        let status = try await runner.runCapture(
            [
                "git", "-C", node.path,
                "status", "--porcelain=v2", "--branch", "-z",
                "--untracked-files=all",
            ],
            env: nil,
            cwd: repoRoot
        )
        let fields = status.split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
        let actualRevision = fields.first(where: {
            $0.hasPrefix("# branch.oid ")
        }).map { String($0.dropFirst("# branch.oid ".count)).lowercased() }
        guard actualRevision == revision else {
            throw ToolingError.message(
                "helper dependency \(identity) checkout does not match Package.resolved"
            )
        }
        guard fields.allSatisfy({ $0.hasPrefix("# ") }) else {
            throw ToolingError.message(
                "helper dependency \(identity) checkout contains local changes"
            )
        }
        records.append(DependencyCheckoutRecord(identity: identity, revision: revision))
    }
    return records
}

private func selectedTargetRecords(
    from package: DescribedPackage,
    products: Set<String>,
    repoRoot: URL,
    fileManager: FileManager
) throws -> [SelectedTargetRecord] {
    let targets = package.targets.filter { target in
        !products.isDisjoint(with: target.productMemberships ?? [])
    }
    for product in products where !targets.contains(where: {
        $0.productMemberships?.contains(product) == true
    }) {
        throw ToolingError.message(
            "SwiftPM did not describe build inputs for product \(product)"
        )
    }

    return try targets.map { target in
        let path = try safeRelativePackagePath(target.path)
        let targetURL = repoRoot.appendingPathComponent(path, isDirectory: true)
        var activeDirectories = Set<String>()
        let inputs = try recursiveInputRecords(
            at: targetURL,
            relativePath: path,
            fileManager: fileManager,
            activeDirectories: &activeDirectories
        )
        return SelectedTargetRecord(
            name: target.name,
            path: path,
            products: (target.productMemberships ?? [])
                .filter { products.contains($0) }
                .sorted(),
            inputs: inputs
        )
    }.sorted {
        ($0.path, $0.name) < ($1.path, $1.name)
    }
}

private func manifestInputRecords(
    repoRoot: URL,
    fileManager: FileManager
) throws -> [InputRecord] {
    let rootEntries = try fileManager.contentsOfDirectory(
        at: repoRoot,
        includingPropertiesForKeys: nil,
        options: []
    )
    let manifestNames = rootEntries.map(\.lastPathComponent).filter { name in
        name == "Package.swift"
            || name.range(
                of: #"^Package@swift-[0-9]+([.][0-9]+)*[.]swift$"#,
                options: .regularExpression
            ) != nil
    }.sorted()
    guard manifestNames.contains("Package.swift") else {
        throw ToolingError.message("SwiftPM package is missing Package.swift")
    }
    return try manifestNames.map { name in
        try regularInputRecord(
            at: repoRoot.appendingPathComponent(name, isDirectory: false),
            relativePath: name
        )
    }
}

private func resolvedInputRecord(
    repoRoot: URL,
    fileManager: FileManager
) throws -> ResolvedInput {
    let url = repoRoot.appendingPathComponent("Package.resolved", isDirectory: false)
    guard fileManager.fileExists(atPath: url.path) else {
        return ResolvedInput(isPresent: false, pins: [])
    }
    let resolved: ResolvedFile
    do {
        resolved = try JSONDecoder().decode(
            ResolvedFile.self,
            from: Data(contentsOf: url)
        )
    } catch {
        throw ToolingError.message("failed to decode Package.resolved: \(error)")
    }
    let pins = resolved.pins.map { pin in
        ResolvedPinRecord(
            identity: pin.identity,
            kind: pin.kind,
            location: pin.location,
            revision: pin.state.revision,
            version: pin.state.version,
            branch: pin.state.branch
        )
    }.sorted { lhs, rhs in
        let left = [lhs.identity, lhs.location ?? "", lhs.revision ?? ""]
        let right = [rhs.identity, rhs.location ?? "", rhs.revision ?? ""]
        return left.lexicographicallyPrecedes(right)
    }
    return ResolvedInput(isPresent: true, pins: pins)
}

private func toolchainRecord(
    destinations: [SwiftPMToolDestination],
    environment: [String: String],
    runner: CommandRunning,
    repoRoot: URL
) async throws -> ToolchainRecord {
    let swiftExecutable = try await requiredCommandOutput(
        ["which", "swift"],
        runner: runner,
        cwd: repoRoot
    )
    let swiftVersion = try await requiredCommandOutput(
        ["swift", "--version"],
        runner: runner,
        cwd: repoRoot
    )
    let xcodeVersion = try await requiredCommandOutput(
        ["xcodebuild", "-version"],
        runner: runner,
        cwd: nil
    )
    let hostTargetInfoOutput = try await requiredCommandOutput(
        ["swift", "-print-target-info"],
        runner: runner,
        cwd: repoRoot
    )
    let hostTargetInfo = try canonicalTargetInfo(hostTargetInfoOutput)
    let macOSSDKBuildVersion = try await requiredCommandOutput(
        ["xcrun", "--sdk", "macosx", "--show-sdk-build-version"],
        runner: runner,
        cwd: nil
    )

    var seenSimulatorTriples = Set<String>()
    var simulatorTargets = [SimulatorToolchainRecord]()
    for destination in destinations {
        guard case let .simulator(sdkPath, triple) = destination,
              seenSimulatorTriples.insert(triple).inserted
        else {
            continue
        }
        let targetInfoOutput = try await requiredCommandOutput(
            ["swift", "-sdk", sdkPath, "-target", triple, "-print-target-info"],
            runner: runner,
            cwd: repoRoot
        )
        let targetInfo = try canonicalTargetInfo(targetInfoOutput)
        let sdkBuildVersion = try await requiredCommandOutput(
            ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-build-version"],
            runner: runner,
            cwd: nil
        )
        simulatorTargets.append(SimulatorToolchainRecord(
            triple: triple,
            targetInfo: targetInfo,
            sdkBuildVersion: sdkBuildVersion
        ))
    }

    let environmentKeys = [
        "CC", "CXX", "DEVELOPER_DIR", "SDKROOT", "SWIFT_EXEC", "TOOLCHAINS",
    ]
    let buildEnvironment = environmentKeys.compactMap { name in
        environment[name].map { EnvironmentRecord(name: name, value: $0) }
    }
    return ToolchainRecord(
        swiftExecutable: swiftExecutable,
        swiftVersion: swiftVersion,
        xcodeVersion: xcodeVersion,
        hostTargetInfo: hostTargetInfo,
        macOSSDKBuildVersion: macOSSDKBuildVersion,
        simulatorTargets: simulatorTargets.sorted { $0.triple < $1.triple },
        buildEnvironment: buildEnvironment
    )
}

private func artifactRecords(
    _ artifacts: [ToolArtifactInput],
    fileManager: FileManager
) throws -> [ToolArtifactDigest] {
    let roles = artifacts.map(\.role)
    guard Set(roles).count == roles.count,
          roles.allSatisfy({ !$0.isEmpty })
    else {
        throw ToolingError.message("tool artifact roles must be unique and nonempty")
    }
    return try artifacts.map { artifact in
        let resolvedURL = artifact.url.resolvingSymlinksInPath()
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: resolvedURL.path)
        } catch {
            throw ToolingError.message(
                "failed to inspect \(artifact.role) at \(artifact.url.path): \(error)"
            )
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ToolingError.message(
                "\(artifact.role) is not a regular file: \(artifact.url.path)"
            )
        }
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        guard permissions & 0o111 != 0 else {
            throw ToolingError.message(
                "\(artifact.role) is not executable: \(artifact.url.path)"
            )
        }
        return ToolArtifactDigest(
            role: artifact.role,
            sha256: try sha256File(resolvedURL)
        )
    }.sorted { $0.role < $1.role }
}

private func recursiveInputRecords(
    at url: URL,
    relativePath: String,
    fileManager: FileManager,
    activeDirectories: inout Set<String>
) throws -> [InputRecord] {
#if canImport(Darwin)
    var metadata = stat()
    let result = url.path.withCString { Darwin.lstat($0, &metadata) }
    guard result == 0 else {
        throw ToolingError.message(
            "failed to inspect SwiftPM build input at \(url.path): errno \(errno)"
        )
    }
    switch metadata.st_mode & mode_t(S_IFMT) {
    case mode_t(S_IFREG):
        return [try regularInputRecord(at: url, relativePath: relativePath)]
    case mode_t(S_IFDIR):
        let directoryIdentity = "\(metadata.st_dev):\(metadata.st_ino)"
        guard activeDirectories.insert(directoryIdentity).inserted else {
            throw ToolingError.message(
                "SwiftPM build inputs contain a directory symlink cycle at \(url.path)"
            )
        }
        defer { activeDirectories.remove(directoryIdentity) }
        let children = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var records = [InputRecord(
            path: relativePath,
            kind: "directory",
            sha256: nil,
            destination: nil
        )]
        for child in children {
            records += try recursiveInputRecords(
                at: child,
                relativePath: "\(relativePath)/\(child.lastPathComponent)",
                fileManager: fileManager,
                activeDirectories: &activeDirectories
            )
        }
        return records
    case mode_t(S_IFLNK):
        let destination = try fileManager.destinationOfSymbolicLink(atPath: url.path)
        var targetMetadata = stat()
        let targetResult = url.path.withCString {
            Darwin.fstatat(AT_FDCWD, $0, &targetMetadata, 0)
        }
        guard targetResult == 0 else {
            throw ToolingError.message(
                "failed to resolve SwiftPM build input symlink at \(url.path): errno \(errno)"
            )
        }
        var records = [InputRecord(
            path: relativePath,
            kind: "symlink",
            sha256: nil,
            destination: destination
        )]
        records += try recursiveInputRecords(
            at: url.resolvingSymlinksInPath(),
            relativePath: "\(relativePath)/@target",
            fileManager: fileManager,
            activeDirectories: &activeDirectories
        )
        return records
    default:
        throw ToolingError.message(
            "unsupported SwiftPM build input at \(url.path)"
        )
    }
#else
    throw ToolingError.message(
        "SwiftPM build input fingerprinting is unavailable on this platform"
    )
#endif
}

private func regularInputRecord(
    at url: URL,
    relativePath: String
) throws -> InputRecord {
    InputRecord(
        path: relativePath,
        kind: "regular",
        sha256: try sha256File(url),
        destination: nil
    )
}

private func safeRelativePackagePath(_ path: String) throws -> String {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !path.isEmpty,
          path != ".",
          !path.hasPrefix("/"),
          components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else {
        throw ToolingError.message("unsafe SwiftPM target path: \(path)")
    }
    return path
}

private func requiredCommandOutput(
    _ command: [String],
    runner: CommandRunning,
    cwd: URL?
) async throws -> String {
    let output = try await runner.runCapture(command, env: nil, cwd: cwd)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !output.isEmpty else {
        throw ToolingError.message(
            "command returned empty identity output: \(command.joined(separator: " "))"
        )
    }
    return output
}

private func canonicalTargetInfo(_ output: String) throws -> TargetInfoRecord {
    struct DecodedTargetInfo: Decodable {
        struct Target: Decodable {
            let triple: String
            let swiftRuntimeCompatibilityVersion: String?
        }

        let compilerVersion: String
        let target: Target
    }
    let decoded: DecodedTargetInfo
    do {
        decoded = try JSONDecoder().decode(
            DecodedTargetInfo.self,
            from: Data(output.utf8)
        )
    } catch {
        throw ToolingError.message("failed to decode Swift target information: \(error)")
    }
    guard !decoded.compilerVersion.isEmpty, !decoded.target.triple.isEmpty else {
        throw ToolingError.message("Swift target information is incomplete")
    }
    return TargetInfoRecord(
        compilerVersion: decoded.compilerVersion,
        triple: decoded.target.triple,
        runtimeCompatibilityVersion: decoded.target.swiftRuntimeCompatibilityVersion
    )
}

private func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

func toolInputSHA256Hex(
    ofFileAt url: URL,
    checkCancellation: () throws -> Void
) throws -> String {
#if canImport(CryptoKit)
    try checkCancellation()
    let handle: FileHandle
    do {
        handle = try FileHandle(forReadingFrom: url)
    } catch {
        throw ToolingError.message("failed to open build input at \(url.path): \(error)")
    }
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
        try checkCancellation()
        let chunk: Data
        do {
            chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
        } catch {
            throw ToolingError.message("failed to read build input at \(url.path): \(error)")
        }
        if chunk.isEmpty {
            break
        }
        hasher.update(data: chunk)
    }
    try checkCancellation()
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
#else
    throw ToolingError.message("SHA-256 is unavailable on this platform")
#endif
}

private func sha256File(_ url: URL) throws -> String {
    try toolInputSHA256Hex(
        ofFileAt: url,
        checkCancellation: { try Task.checkCancellation() }
    )
}

private func sha256Hex(_ data: Data) throws -> String {
#if canImport(CryptoKit)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
#else
    throw ToolingError.message("SHA-256 is unavailable on this platform")
#endif
}
