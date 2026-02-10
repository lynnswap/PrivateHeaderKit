import Foundation

public struct RuntimeInfo: Codable, Equatable {
    public let version: String
    public let build: String
    public let identifier: String
    public let runtimeRoot: String
}

public struct DeviceInfo: Codable, Equatable {
    public let name: String
    public let udid: String
    public var state: String
}

public enum Simctl {
    private struct RuntimeList: Decodable {
        struct RuntimeEntry: Decodable {
            let name: String?
            let version: String?
            let identifier: String?
            let runtimeRoot: String?
            let isAvailable: Bool?
            let buildversion: String?
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
        struct DeviceTypeEntry: Decodable {
            let name: String?
            let identifier: String?
            let productFamily: String?
        }
        let devicetypes: [DeviceTypeEntry]?
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
            results.append(RuntimeInfo(version: version, build: build, identifier: identifier, runtimeRoot: runtimeRoot))
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
        if let booted = devices.first(where: { $0.state == "Booted" }) {
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
        return try cloneDevice(base: base, runtimeId: runtime.identifier, cloneName: cloneName, runner: runner)
    }

    public static func ensureDeviceBooted(_ device: inout DeviceInfo, runner: CommandRunning, force: Bool) throws {
        if device.state == "Booted", !force { return }
        print("Booting simulator: \(device.name) (\(device.udid))")
        try runner.runSimple(["xcrun", "simctl", "boot", device.udid], env: nil, cwd: nil)
        try runner.runSimple(["xcrun", "simctl", "bootstatus", device.udid, "-b"], env: nil, cwd: nil)
        device.state = "Booted"
    }

    public static func createDefaultDevice(runtimeId: String, version: String, runner: CommandRunning) throws {
        let output = try runner.runCapture(["xcrun", "simctl", "list", "devicetypes", "-j"], env: nil, cwd: nil)
        let data = Data(output.utf8)
        let decoded = try JSONDecoder().decode(DeviceTypesList.self, from: data)
        let deviceTypes = decoded.devicetypes ?? []

        func matchesEnv(_ entry: DeviceTypesList.DeviceTypeEntry, needle: String) -> Bool {
            if entry.identifier == needle || entry.name == needle { return true }
            return (entry.identifier ?? "").lowercased() == needle.lowercased() || (entry.name ?? "").lowercased() == needle.lowercased()
        }

        var choice: DeviceTypesList.DeviceTypeEntry?
        if let envType = ProcessInfo.processInfo.environment["PH_DEVICE_TYPE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
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
        guard let picked = choice,
              let deviceName = picked.name, !deviceName.isEmpty,
              let deviceType = picked.identifier, !deviceType.isEmpty
        else {
            throw ToolingError.message("no device types available")
        }

        let createdName = "\(deviceName) (\(version))"
        print("Creating device: \(createdName)")
        try runner.runSimple(["xcrun", "simctl", "create", createdName, deviceType, runtimeId], env: nil, cwd: nil)
    }
}

