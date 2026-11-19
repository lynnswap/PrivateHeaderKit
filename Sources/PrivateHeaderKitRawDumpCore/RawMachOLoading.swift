import Foundation
@_spi(Support) import MachOKit
import PrivateHeaderKitExecutableResolution

enum RawMachO {
    case file(MachOFile)
    case loaded(MachOImage)

    func validateFileBackedChainedFixups() throws {
        guard case .file(let file) = self else { return }
        try file.validateChainedFixups()
    }
}

enum RawMachOLoadError: Error, Equatable, CustomStringConvertible, Sendable {
    case sharedCacheMissAndDiskLoadFailed(
        inputPath: String,
        cacheUUID: UUID,
        normalizedCandidates: [String],
        diskError: String
    )
    case diskLoadFailed(inputPath: String, diskError: String)

    var description: String {
        switch self {
        case .sharedCacheMissAndDiskLoadFailed(
            let inputPath,
            let cacheUUID,
            let normalizedCandidates,
            let diskError
        ):
            "raw Mach-O target was absent from shared cache and could not be loaded from disk: input=\(inputPath) cacheUUID=\(cacheUUID.uuidString.lowercased()) candidates=\(normalizedCandidates.joined(separator: ",")) diskError=\(diskError)"
        case .diskLoadFailed(let inputPath, let diskError):
            "raw Mach-O target could not be loaded from disk: input=\(inputPath) diskError=\(diskError)"
        }
    }
}

struct RawMachOLoader {
    private let sharedCache: DyldSharedCacheAccess?
    private let environment: [String: String]
    private let diskLoader: (URL) throws -> RawMachO?

    init(
        options: DumpOptions,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sharedCacheFactory: (UUID?) throws -> DyldSharedCacheAccess = DyldSharedCacheAccess.current,
        diskLoader: @escaping (URL) throws -> RawMachO? = loadSupportedDiskMachO
    ) throws {
        self.environment = environment
        self.diskLoader = diskLoader
        if options.useSharedCache {
            guard let expectedCacheUUID = options.expectedCacheUUID else {
                throw DyldSharedCacheAccessError.missingExpectedUUID
            }
            try validateLoadedCacheEnvironment(environment)
            self.sharedCache = try sharedCacheFactory(expectedCacheUUID)
        } else {
            self.sharedCache = nil
        }
    }

    func load(url: URL) throws -> RawMachO? {
        if let sharedCache {
            let candidates = normalizedCacheImagePaths(
                for: url.path,
                environment: environment
            )
            if let loaded = sharedCache.image(matching: candidates) {
                return .loaded(loaded.machO)
            }

            do {
                return try diskLoader(url)
            } catch {
                throw RawMachOLoadError.sharedCacheMissAndDiskLoadFailed(
                    inputPath: url.path,
                    cacheUUID: sharedCache.cacheUUID,
                    normalizedCandidates: candidates,
                    diskError: String(describing: error)
                )
            }
        }

        do {
            return try diskLoader(url)
        } catch {
            throw RawMachOLoadError.diskLoadFailed(
                inputPath: url.path,
                diskError: String(describing: error)
            )
        }
    }
}

private func loadSupportedDiskMachO(url: URL) throws -> RawMachO? {
    let file = try loadFromFile(url: url)
    switch file {
    case .machO(let machO):
        return isSupported(machO) ? .file(machO) : nil
    case .fat(let fat):
        let machOFiles = try fat.machOFiles()
        if let match = machOFiles.first(where: { isSupported($0) }) {
            return .file(match)
        }
        return nil
    }
}

private func isSupported(_ machO: MachOFile) -> Bool {
    switch machO.header.cpuType {
    case .arm64, .x86_64:
        return true
    default:
        return false
    }
}

func normalizedCacheImagePaths(
    for path: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> [String] {
    ExecutableResolution.normalizedCacheImagePaths(
        for: path,
        environment: environment
    )
}
