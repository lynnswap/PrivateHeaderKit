import Foundation
import MachOKit
import MachOSwiftSection
import SwiftDeclaration
import SwiftDeclarationRendering
import SwiftInterface

protocol SwiftInterfaceBuilding {
    func prepare() async throws
    func printRoot() async throws -> String
}

protocol SwiftInterfaceBuildingFactory {
    func makeBuilder(machO: MachOFile) throws -> SwiftInterfaceBuilding
    func makeBuilder(machO: MachOImage) throws -> SwiftInterfaceBuilding
}

struct DefaultSwiftInterfaceBuilderFactory: SwiftInterfaceBuildingFactory {
    let configuration: SwiftInterfaceBuilderConfiguration
    let eventHandlers: [SwiftIndexEvents.Handler]

    init(
        configuration: SwiftInterfaceBuilderConfiguration = .init(),
        eventHandlers: [SwiftIndexEvents.Handler] = []
    ) {
        self.configuration = configuration
        self.eventHandlers = eventHandlers
    }

    func makeBuilder(machO: MachOFile) throws -> SwiftInterfaceBuilding {
        try SwiftInterfaceBuilderAdapter(
            machO: machO,
            configuration: configuration,
            eventHandlers: eventHandlers
        )
    }

    func makeBuilder(machO: MachOImage) throws -> SwiftInterfaceBuilding {
        try SwiftInterfaceBuilderAdapter(
            machO: machO,
            configuration: configuration,
            eventHandlers: eventHandlers
        )
    }
}

struct SwiftInterfaceBuilderAdapter<MachO: FieldLayoutRenderable>: SwiftInterfaceBuilding {
    private let builder: SwiftInterfaceBuilder<MachO>

    init(
        machO: MachO,
        configuration: SwiftInterfaceBuilderConfiguration = .init(),
        eventHandlers: [SwiftIndexEvents.Handler] = []
    ) throws {
        self.builder = try SwiftInterfaceBuilder(configuration: configuration, eventHandlers: eventHandlers, in: machO)
    }

    func prepare() async throws {
        try await builder.prepare()
    }

    func printRoot() async throws -> String {
        try await builder.printRoot().string
    }
}

func dumpSwift(
    machO: RawMachO,
    imagePath: String,
    outputDir: URL,
    options: DumpOptions,
    interfaceBuilderFactory: SwiftInterfaceBuildingFactory,
    fileManager: FileManager
) async throws {
    switch machO {
    case .file(let file):
        try await dumpSwift(
            machO: file,
            imagePath: imagePath,
            outputDir: outputDir,
            options: options,
            interfaceBuilderFactory: interfaceBuilderFactory,
            fileManager: fileManager
        )
    case .loaded(let image):
        try await dumpSwift(
            machO: image,
            imagePath: imagePath,
            outputDir: outputDir,
            options: options,
            interfaceBuilderFactory: interfaceBuilderFactory,
            fileManager: fileManager
        )
    }
}

func dumpSwift(
    machO: MachOFile,
    imagePath: String,
    outputDir: URL,
    options: DumpOptions,
    interfaceBuilderFactory: SwiftInterfaceBuildingFactory = DefaultSwiftInterfaceBuilderFactory(),
    fileManager: FileManager
) async throws {
    if shouldSkipSwiftInterface(imagePath: imagePath, outputDir: outputDir, options: options, fileManager: fileManager) {
        return
    }
    let builder = try interfaceBuilderFactory.makeBuilder(machO: machO)
    try await dumpSwift(
        builder: builder,
        imagePath: imagePath,
        outputDir: outputDir,
        options: options,
        fileManager: fileManager
    )
}

func dumpSwift(
    machO: MachOImage,
    imagePath: String,
    outputDir: URL,
    options: DumpOptions,
    interfaceBuilderFactory: SwiftInterfaceBuildingFactory = DefaultSwiftInterfaceBuilderFactory(),
    fileManager: FileManager
) async throws {
    if shouldSkipSwiftInterface(imagePath: imagePath, outputDir: outputDir, options: options, fileManager: fileManager) {
        return
    }
    let builder = try interfaceBuilderFactory.makeBuilder(machO: machO)
    try await dumpSwift(
        builder: builder,
        imagePath: imagePath,
        outputDir: outputDir,
        options: options,
        fileManager: fileManager
    )
}

func dumpSwift(
    builder: SwiftInterfaceBuilding,
    imagePath: String,
    outputDir: URL,
    options: DumpOptions,
    fileManager: FileManager
) async throws {
    try await dumpSwiftInterface(
        imagePath: imagePath,
        outputDir: outputDir,
        options: options,
        fileManager: fileManager,
        buildInterface: {
            let prepareStart = profileNowNanoseconds(enabled: options.profile)
            try await builder.prepare()
            profileLogDuration(enabled: options.profile, imagePath: imagePath, name: "dumpSwift.prepare", since: prepareStart)

            let printStart = profileNowNanoseconds(enabled: options.profile)
            let text = try await builder.printRoot()
            profileLogDuration(enabled: options.profile, imagePath: imagePath, name: "dumpSwift.printRoot", since: printStart)
            return text
        }
    )
}

func swiftInterfaceOutputURL(imagePath: String, outputDir: URL) -> URL {
    let moduleName = URL(fileURLWithPath: imagePath).lastPathComponent
    return outputDir.appendingPathComponent(safeFileName(baseName: moduleName, extension: ".swiftinterface"))
}

func shouldSkipSwiftInterface(
    imagePath: String,
    outputDir: URL,
    options: DumpOptions,
    fileManager: FileExistenceChecking
) -> Bool {
    options.skipExisting && fileManager.fileExists(atPath: swiftInterfaceOutputURL(imagePath: imagePath, outputDir: outputDir).path)
}

func dumpSwiftInterface(
    imagePath: String,
    outputDir: URL,
    options: DumpOptions,
    fileManager: FileManager,
    buildInterface: () async throws -> String
) async throws {
    let outputURL = swiftInterfaceOutputURL(imagePath: imagePath, outputDir: outputDir)

    if shouldSkipSwiftInterface(imagePath: imagePath, outputDir: outputDir, options: options, fileManager: fileManager) {
        return
    }

    do {
        let text = try await withSilencedStdout(!options.verbose) {
            try await buildInterface()
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let writeStart = profileNowNanoseconds(enabled: options.profile)
        try text.write(to: outputURL, atomically: true, encoding: .utf8)
        profileLogDuration(enabled: options.profile, imagePath: imagePath, name: "dumpSwift.writeFile", since: writeStart)
    } catch {
        if options.verbose {
            fputs("Swift interface generation failed for \(imagePath): \(error)\n", stderr)
        }
        throw error
    }
}
