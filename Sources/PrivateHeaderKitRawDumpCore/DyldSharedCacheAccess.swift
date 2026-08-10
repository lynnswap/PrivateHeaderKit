import Foundation
import MachOKit
import PrivateHeaderKitHelperProtocol

enum DyldSharedCacheAccessError: Error, Equatable, CustomStringConvertible, Sendable {
    case unavailable
    case missingSlide
    case missingImageInventory
    case missingImagePath(index: Int)
    case invalidImagePath(index: Int, path: String)
    case invalidImageAddress(path: String)
    case missingExpectedUUID
    case expectedUUIDMismatch(expected: UUID, actual: UUID)
    case missingSimulatorRuntimeRoot
    case simulatorRuntimeRootMismatch(expected: String, actual: String)
    case unsupportedHostRuntimeRoot(String)

    var description: String {
        switch self {
        case .unavailable:
            "the current process has no loaded dyld shared cache"
        case .missingSlide:
            "the loaded dyld shared cache has no mapping slide"
        case .missingImageInventory:
            "the loaded dyld shared cache has no image inventory"
        case .missingImagePath(let index):
            "the loaded dyld shared cache image at index \(index) has no logical path"
        case .invalidImagePath(let index, let path):
            "the loaded dyld shared cache image at index \(index) has an invalid logical path: \(path)"
        case .invalidImageAddress(let path):
            "the loaded dyld shared cache contains an invalid image address for \(path)"
        case .missingExpectedUUID:
            "shared-cache dumping requires --expected-cache-uuid"
        case .expectedUUIDMismatch(let expected, let actual):
            "dyld shared-cache UUID mismatch: expected \(expected.uuidString.lowercased()), got \(actual.uuidString.lowercased())"
        case .missingSimulatorRuntimeRoot:
            "shared-cache dumping in a simulator requires PH_RUNTIME_ROOT to identify the running runtime"
        case .simulatorRuntimeRootMismatch(let expected, let actual):
            "simulator runtime root mismatch: expected \(expected), got \(actual)"
        case .unsupportedHostRuntimeRoot(let root):
            "the host helper cannot use its loaded dyld shared cache for custom runtime root \(root)"
        }
    }
}

struct LoadedDyldCacheImage {
    let logicalPath: String
    let machO: MachOImage
}

struct DyldSharedCacheAccess {
    let cacheUUID: UUID
    let images: [LoadedDyldCacheImage]

    static func current(expectedUUID: UUID? = nil) throws -> DyldSharedCacheAccess {
        guard let cache = DyldCacheLoaded.current else {
            throw DyldSharedCacheAccessError.unavailable
        }
        return try make(cache: cache, expectedUUID: expectedUUID)
    }

    static func make(
        cache: DyldCacheLoaded,
        expectedUUID: UUID? = nil
    ) throws -> DyldSharedCacheAccess {
        let actualUUID = cache.header.uuid
        try validateExpectedCacheUUID(expectedUUID, actual: actualUUID)

        guard let slide = cache.slide else {
            throw DyldSharedCacheAccessError.missingSlide
        }
        guard let imageInfos = cache.imageInfos else {
            throw DyldSharedCacheAccessError.missingImageInventory
        }

        let images = try imageInfos.enumerated().map { index, info in
            guard let logicalPath = info.path(in: cache) else {
                throw DyldSharedCacheAccessError.missingImagePath(index: index)
            }
            guard isAbsoluteLogicalImagePath(logicalPath) else {
                throw DyldSharedCacheAccessError.invalidImagePath(
                    index: index,
                    path: logicalPath
                )
            }
            guard let address = Int(exactly: info.address) else {
                throw DyldSharedCacheAccessError.invalidImageAddress(path: logicalPath)
            }
            let (slidAddress, overflow) = address.addingReportingOverflow(slide)
            guard !overflow,
                  let pointer = UnsafeRawPointer(bitPattern: slidAddress)
            else {
                throw DyldSharedCacheAccessError.invalidImageAddress(path: logicalPath)
            }
            return LoadedDyldCacheImage(
                logicalPath: logicalPath,
                machO: MachOImage(pointer: pointer)
            )
        }
        return DyldSharedCacheAccess(cacheUUID: actualUUID, images: images)
    }

    func image(matching candidates: [String]) -> LoadedDyldCacheImage? {
        guard let logicalPath = exactCacheImagePathMatch(
            candidates: candidates,
            inventory: logicalImagePaths
        ) else {
            return nil
        }
        return images.first { $0.logicalPath == logicalPath }
    }

    var logicalImagePaths: [String] {
        images.map(\.logicalPath)
    }
}

func validateExpectedCacheUUID(_ expected: UUID?, actual: UUID) throws {
    guard let expected else { return }
    guard expected == actual else {
        throw DyldSharedCacheAccessError.expectedUUIDMismatch(
            expected: expected,
            actual: actual
        )
    }
}

func validateLoadedCacheEnvironment(_ environment: [String: String]) throws {
    let requestedRoot = environment["PH_RUNTIME_ROOT"]
        ?? environment["SIMCTL_CHILD_PH_RUNTIME_ROOT"]

    if let simulatorRoot = environment["SIMULATOR_ROOT"] {
        guard let requestedRoot else {
            throw DyldSharedCacheAccessError.missingSimulatorRuntimeRoot
        }
        let expected = standardizedRootPath(simulatorRoot)
        let actual = standardizedRootPath(requestedRoot)
        guard expected == actual else {
            throw DyldSharedCacheAccessError.simulatorRuntimeRootMismatch(
                expected: expected,
                actual: actual
            )
        }
        return
    }

    if let requestedRoot {
        let standardized = standardizedRootPath(requestedRoot)
        guard standardized == "/" else {
            throw DyldSharedCacheAccessError.unsupportedHostRuntimeRoot(standardized)
        }
    }
}

private func standardizedRootPath(_ path: String) -> String {
    URL(fileURLWithPath: path, isDirectory: true)
        .resolvingSymlinksInPath()
        .standardizedFileURL
        .path
}

private func isAbsoluteLogicalImagePath(_ path: String) -> Bool {
    guard path.first == "/", path.count > 1 else { return false }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    return !components.dropFirst().contains { component in
        component.isEmpty || component == "." || component == ".."
    }
}

func exactCacheImagePathMatch(
    candidates: [String],
    inventory: [String]
) -> String? {
    let candidateSet = Set(candidates)
    return inventory.first { candidateSet.contains($0) }
}

func makeSharedCacheInventory(
    access: DyldSharedCacheAccess
) throws -> PrivateHeaderKitSharedCacheInventory {
    try PrivateHeaderKitSharedCacheInventory(
        cacheUUID: access.cacheUUID,
        imagePaths: access.logicalImagePaths
    )
}

func makeSharedCacheInventory(
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws -> PrivateHeaderKitSharedCacheInventory {
    try validateLoadedCacheEnvironment(environment)
    return try makeSharedCacheInventory(access: .current())
}

func encodeSharedCacheInventory(
    _ inventory: PrivateHeaderKitSharedCacheInventory,
    encoder: JSONEncoder = JSONEncoder()
) throws -> Data {
    try encoder.encode(inventory)
}

private extension MachOImage {
    init(pointer: UnsafeRawPointer) {
        self.init(ptr: pointer.assumingMemoryBound(to: mach_header.self))
    }
}
