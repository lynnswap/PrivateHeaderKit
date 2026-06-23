import Foundation

public struct DeviceTypeInfo: Codable, Equatable, Sendable {
    public let name: String?
    public let identifier: String?
    public let productFamily: String?
    public let minRuntimeVersionString: String?
    public let maxRuntimeVersionString: String?
    public let minRuntimeVersion: Int?
    public let maxRuntimeVersion: Int?

    public init(
        name: String?,
        identifier: String?,
        productFamily: String?,
        minRuntimeVersionString: String? = nil,
        maxRuntimeVersionString: String? = nil,
        minRuntimeVersion: Int? = nil,
        maxRuntimeVersion: Int? = nil
    ) {
        self.name = name
        self.identifier = identifier
        self.productFamily = productFamily
        self.minRuntimeVersionString = minRuntimeVersionString
        self.maxRuntimeVersionString = maxRuntimeVersionString
        self.minRuntimeVersion = minRuntimeVersion
        self.maxRuntimeVersion = maxRuntimeVersion
    }
}

public struct RuntimeInfo: Codable, Equatable, Sendable {
    public let version: String
    public let build: String
    public let identifier: String
    public let runtimeRoot: String
    public let supportedDeviceTypes: [DeviceTypeInfo]

    public init(
        version: String,
        build: String,
        identifier: String,
        runtimeRoot: String,
        supportedDeviceTypes: [DeviceTypeInfo] = []
    ) {
        self.version = version
        self.build = build
        self.identifier = identifier
        self.runtimeRoot = runtimeRoot
        self.supportedDeviceTypes = supportedDeviceTypes
    }
}

public struct DeviceInfo: Codable, Equatable, Sendable {
    public let name: String
    public let udid: String
    public var state: String
}

public enum Simctl {
    private static func stateEquals(_ state: String, _ expected: String) -> Bool {
        state.caseInsensitiveCompare(expected) == .orderedSame
    }

    private struct RuntimeList: Decodable {
        struct RuntimeEntry: Decodable {
            let name: String?
            let version: String?
            let identifier: String?
            let runtimeRoot: String?
            let isAvailable: Bool?
            let buildversion: String?
            let supportedDeviceTypes: [DeviceTypeInfo]?
        }
        let runtimes: [RuntimeEntry]?
    }

    private struct DevicesList: Decodable {
        struct DeviceEntry: Decodable {
            let name: String?
            let udid: String?
            let state: String?
        }
        let devices: [String: [DeviceEntry]]?
    }

    private struct DeviceTypesList: Decodable {
        let devicetypes: [DeviceTypeInfo]?
    }

    public static func listRuntimes(runner: CommandRunning) throws -> [RuntimeInfo] {
        let output = try runner.runCapture(["xcrun", "simctl", "list", "runtimes", "-j"], env: nil, cwd: nil)
        let data = Data(output.utf8)
        let decoded = try JSONDecoder().decode(RuntimeList.self, from: data)

        var results: [RuntimeInfo] = []
        for entry in decoded.runtimes ?? [] {
            let name = entry.name ?? ""
            guard name.hasPrefix("iOS") else { continue }
            guard entry.isAvailable == true else { continue }
            guard let version = entry.version, !version.isEmpty else { continue }
            guard let identifier = entry.identifier, !identifier.isEmpty else { continue }
            guard let runtimeRoot = entry.runtimeRoot, !runtimeRoot.isEmpty else { continue }
            let build = entry.buildversion ?? ""
            results.append(
                RuntimeInfo(
                    version: version,
                    build: build,
                    identifier: identifier,
                    runtimeRoot: runtimeRoot,
                    supportedDeviceTypes: entry.supportedDeviceTypes ?? []
                )
            )
        }

        results.sort { VersionUtils.versionKey($0.version).lexicographicallyPrecedes(VersionUtils.versionKey($1.version)) }
        return results
    }

    public static func findRuntime(version: String, runner: CommandRunning) throws -> RuntimeInfo {
        for runtime in try listRuntimes(runner: runner) where runtime.version == version {
            return runtime
        }
        throw ToolingError.message("iOS runtime not found or unavailable: \(version)")
    }

    public static func findRuntime(version: String, build: String?, runner: CommandRunning) throws -> RuntimeInfo {
        let matches = try listRuntimes(runner: runner).filter { $0.version == version }
        guard !matches.isEmpty else {
            throw ToolingError.message("iOS runtime not found or unavailable: \(version)")
        }

        guard let build, !build.isEmpty else {
            return matches[0]
        }
        if let match = matches.first(where: { $0.build == build }) {
            return match
        }
        throw ToolingError.message("iOS runtime not found or unavailable: \(version) (\(build))")
    }

    public static func latestRuntime(runner: CommandRunning) throws -> RuntimeInfo {
        let runtimes = try listRuntimes(runner: runner)
        guard let last = runtimes.last else {
            throw ToolingError.message("no available iOS runtimes found")
        }
        return last
    }

    public static func listDevices(runtimeId: String, runner: CommandRunning) throws -> [DeviceInfo] {
        let output = try runner.runCapture(["xcrun", "simctl", "list", "devices", "-j"], env: nil, cwd: nil)
        let data = Data(output.utf8)
        let decoded = try JSONDecoder().decode(DevicesList.self, from: data)
        let devices = decoded.devices?[runtimeId] ?? []
        return devices.map {
            DeviceInfo(name: $0.name ?? "", udid: $0.udid ?? "", state: $0.state ?? "")
        }
    }

    public static func matchDevice(devices: [DeviceInfo], query: String) -> DeviceInfo? {
        let needle = query.lowercased()
        if let match = devices.first(where: { $0.udid.lowercased() == needle }) {
            return match
        }
        if let match = devices.first(where: { $0.name.lowercased() == needle }) {
            return match
        }
        return nil
    }

    public static func pickDefaultDevice(devices: [DeviceInfo]) throws -> DeviceInfo {
        guard let first = devices.first else {
            throw ToolingError.message("no devices available")
        }
        if let shutdown = devices.first(where: { stateEquals($0.state, "Shutdown") }) {
            return shutdown
        }
        if let booted = devices.first(where: { stateEquals($0.state, "Booted") }) {
            return booted
        }
        return first
    }

    public static func defaultCloneName(version: String) -> String {
        "Dumping Device (iOS \(version))"
    }

    public static func cloneDevice(base: DeviceInfo, runtimeId: String, cloneName: String, runner: CommandRunning) throws -> DeviceInfo {
        print("Cloning simulator: \(base.name) -> \(cloneName)")
        let output = try runner.runCapture(["xcrun", "simctl", "clone", base.udid, cloneName], env: nil, cwd: nil)

        let udid = output.split(separator: "\n").reversed().first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }).map(String.init) ?? ""
        if !udid.isEmpty {
            return DeviceInfo(name: cloneName, udid: udid, state: "Shutdown")
        }

        let refreshed = try listDevices(runtimeId: runtimeId, runner: runner)
        if let match = matchDevice(devices: refreshed, query: cloneName) {
            return match
        }
        throw ToolingError.message("failed to determine cloned simulator udid")
    }

    public static func resolveDefaultDevice(runtime: RuntimeInfo, devices: [DeviceInfo], runner: CommandRunning) throws -> DeviceInfo {
        let cloneName = defaultCloneName(version: runtime.version)
        if let clone = matchDevice(devices: devices, query: cloneName) {
            return clone
        }
        let base = try pickDefaultDevice(devices: devices)
        if base.name == cloneName {
            return base
        }
        if !stateEquals(base.state, "Shutdown") {
            return base
        }
        return try cloneDevice(base: base, runtimeId: runtime.identifier, cloneName: cloneName, runner: runner)
    }

    public static func resolveDevice(
        runtime: RuntimeInfo,
        query: String?,
        runner: CommandRunning,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> DeviceInfo {
        var devices = try listDevices(runtimeId: runtime.identifier, runner: runner)
        if devices.isEmpty {
            try createDefaultDevice(runtime: runtime, runner: runner, environment: environment)
            devices = try listDevices(runtimeId: runtime.identifier, runner: runner)
        }

        let selected: DeviceInfo
        if let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            guard let match = matchDevice(devices: devices, query: query) else {
                throw ToolingError.message("simulator device not found for iOS \(runtime.version): \(query)")
            }
            selected = match
        } else {
            selected = try resolveDefaultDevice(runtime: runtime, devices: devices, runner: runner)
        }

        var booted = selected
        try ensureDeviceBooted(&booted, runner: runner, force: false)
        return booted
    }

    public static func ensureDeviceBooted(_ device: inout DeviceInfo, runner: CommandRunning, force: Bool) throws {
        if stateEquals(device.state, "Booted"), !force { return }
        print("Booting simulator: \(device.name) (\(device.udid))")
        try runner.runSimple(["xcrun", "simctl", "boot", device.udid], env: nil, cwd: nil)
        try runner.runSimple(["xcrun", "simctl", "bootstatus", device.udid, "-b"], env: nil, cwd: nil)
        device.state = "Booted"
    }

    public static func createDefaultDevice(
        runtimeId: String,
        version: String,
        runner: CommandRunning,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        try createDefaultDevice(
            runtime: RuntimeInfo(version: version, build: "", identifier: runtimeId, runtimeRoot: ""),
            runner: runner,
            environment: environment
        )
    }

    public static func createDefaultDevice(
        runtime: RuntimeInfo,
        runner: CommandRunning,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let deviceTypes = try defaultDeviceTypeCandidates(for: runtime, runner: runner)

        func matchesEnv(_ entry: DeviceTypeInfo, needle: String) -> Bool {
            if entry.identifier == needle || entry.name == needle { return true }
            return (entry.identifier ?? "").lowercased() == needle.lowercased() || (entry.name ?? "").lowercased() == needle.lowercased()
        }

        var choice: DeviceTypeInfo?
        if let envType = environment["PH_DEVICE_TYPE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envType.isEmpty {
            choice = deviceTypes.first(where: { matchesEnv($0, needle: envType) })
            if choice == nil {
                throw ToolingError.message("device type not found: \(envType)")
            }
        }

        if choice == nil {
            choice = deviceTypes.first(where: { $0.productFamily == "iPhone" })
        }
        if choice == nil {
            choice = deviceTypes.first(where: { ($0.name ?? "").hasPrefix("iPhone") })
        }
        if choice == nil {
            choice = deviceTypes.first
        }
        guard let picked = choice,
              let deviceName = picked.name, !deviceName.isEmpty,
              let deviceType = picked.identifier, !deviceType.isEmpty
        else {
            throw ToolingError.message("no device types available")
        }

        let createdName = "\(deviceName) (\(runtime.version))"
        print("Creating device: \(createdName)")
        try runner.runSimple(["xcrun", "simctl", "create", createdName, deviceType, runtime.identifier], env: nil, cwd: nil)
    }

    private static func defaultDeviceTypeCandidates(for runtime: RuntimeInfo, runner: CommandRunning) throws -> [DeviceTypeInfo] {
        if !runtime.supportedDeviceTypes.isEmpty {
            return runtime.supportedDeviceTypes
        }

        let output = try runner.runCapture(["xcrun", "simctl", "list", "devicetypes", "-j"], env: nil, cwd: nil)
        let data = Data(output.utf8)
        let decoded = try JSONDecoder().decode(DeviceTypesList.self, from: data)
        let deviceTypes = decoded.devicetypes ?? []
        return compatibleDeviceTypes(from: deviceTypes, runtime: runtime) ?? deviceTypes
    }

    private static func compatibleDeviceTypes(from deviceTypes: [DeviceTypeInfo], runtime: RuntimeInfo) -> [DeviceTypeInfo]? {
        let hasRuntimeMetadata = deviceTypes.contains { deviceType in
            hasRuntimeBoundMetadata(deviceType)
        }
        guard hasRuntimeMetadata else {
            return nil
        }
        return deviceTypes.filter { supports(runtime: runtime, deviceType: $0) }
    }

    private static func supports(runtime: RuntimeInfo, deviceType: DeviceTypeInfo) -> Bool {
        let runtimeVersionKey = VersionUtils.versionKey(runtime.version)
        if let min = normalizedVersionString(deviceType.minRuntimeVersionString),
           compareVersionStrings(runtime.version, min) == .orderedAscending {
            return false
        }
        if let max = normalizedVersionString(deviceType.maxRuntimeVersionString),
           compareVersionStrings(runtime.version, max) == .orderedDescending {
            return false
        }
        if let min = coreSimulatorVersionKey(deviceType.minRuntimeVersion),
           compareVersionKeys(runtimeVersionKey, min) == .orderedAscending {
            return false
        }
        if let max = coreSimulatorVersionKey(deviceType.maxRuntimeVersion),
           compareVersionKeys(runtimeVersionKey, max) == .orderedDescending {
            return false
        }
        return true
    }

    private static func hasRuntimeBoundMetadata(_ deviceType: DeviceTypeInfo) -> Bool {
        hasText(deviceType.minRuntimeVersionString)
            || hasText(deviceType.maxRuntimeVersionString)
            || deviceType.minRuntimeVersion != nil
            || deviceType.maxRuntimeVersion != nil
    }

    private static func normalizedVersionString(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func hasText(_ value: String?) -> Bool {
        normalizedVersionString(value) != nil
    }

    private static func compareVersionStrings(_ lhs: String, _ rhs: String) -> ComparisonResult {
        compareVersionKeys(VersionUtils.versionKey(lhs), VersionUtils.versionKey(rhs))
    }

    private static func compareVersionKeys(_ left: [Int], _ right: [Int]) -> ComparisonResult {
        let count = max(left.count, right.count)
        for index in 0..<count {
            let leftValue = index < left.count ? left[index] : 0
            let rightValue = index < right.count ? right[index] : 0
            if leftValue < rightValue { return .orderedAscending }
            if leftValue > rightValue { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func coreSimulatorVersionKey(_ value: Int?) -> [Int]? {
        guard let value else { return nil }
        return [
            (value >> 16) & 0xffff,
            (value >> 8) & 0xff,
            value & 0xff,
        ]
    }
}
