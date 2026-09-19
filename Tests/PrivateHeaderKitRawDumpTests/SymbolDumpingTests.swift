import Foundation
import MachOKit
import PrivateHeaderKitHelperProtocol
import Testing
@testable import PrivateHeaderKitRawDumpCore

struct SymbolDumpingTests {
    @Test(arguments: [String(repeating: "a", count: 255), String(repeating: "\u{3042}", count: 85)])
    func longImageNamesRemainWritableAndKeepTheirIdentity(_ name: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent(name)
        try symbolMachOFixture().write(to: input)
        let output = root.appendingPathComponent("output")
        try dumpSymbols(machO: .file(MachOFile(url: input)), imagePath: input.path, outputDir: output, options: .init(outputDir: output))
        let files = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
        let symbols = try #require(files.first)
        #expect(symbols.lastPathComponent.utf8.count <= 255)
        #expect(symbols.lastPathComponent.hasSuffix(".symbols.tsv"))
        #expect(try PrivateHeaderKitSymbolList(tsv: String(contentsOf: symbols, encoding: .utf8)).imagePath == input.path)
        let swift = swiftInterfaceOutputURL(imagePath: input.path, outputDir: output)
        try "interface".write(to: swift, atomically: true, encoding: .utf8)
        #expect(swift.lastPathComponent.utf8.count <= 255)
        #expect(swift != swiftInterfaceOutputURL(imagePath: input.path + "b", outputDir: output))
    }

    @Test func diskAndLoadedImagesMergeExportsAndLocalSymbols() throws {
        let data = symbolMachOFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("Fixture")
        try data.write(to: fileURL)
        let file = try MachOFile(url: fileURL)
        let disk = makeSearchableSymbolList(machO: file, imagePath: "/Fixture")
        let memory = UnsafeMutableRawPointer.allocate(byteCount: data.count, alignment: 16)
        defer { memory.deallocate() }
        data.copyBytes(to: memory.assumingMemoryBound(to: UInt8.self), count: data.count)
        let loaded = makeSearchableSymbolList(
            machO: MachOImage(ptr: memory.assumingMemoryBound(to: mach_header.self)), imagePath: "/Fixture"
        )
        #expect(disk == loaded)
        #expect(disk.symbols.map(\.name) == ["__Z3fooi", "_only_export", "_shared"])
        #expect(disk.symbols.map(\.visibility) == [.local, .export, .export])
        #expect(disk.symbols[0].demangledName == "foo(int)")
        try dumpSymbols(machO: .file(file), imagePath: "/Fixture", outputDir: directory, options: .init(outputDir: directory))
        let output = directory.appendingPathComponent("Fixture.symbols.tsv")
        #expect(try PrivateHeaderKitSymbolList(tsv: String(contentsOf: output, encoding: .utf8)) == disk)
    }

    @Test func demanglesMachOCXXSwiftAndOrdinaryNames() {
        #expect(demangleSearchableSymbol("__ZNK8PHKProbe6Engine7computeEi") == "PHKProbe::Engine::compute(int) const")
        #expect(demangleSearchableSymbol("__ZTVN8PHKProbe6EngineE") == "vtable for PHKProbe::Engine")
        #expect(demangleSearchableSymbol("_$s4Test3fooyyF") == "Test.foo() -> ()")
        #expect(demangleSearchableSymbol("_CFunction") == "_CFunction")
        #expect(demangleSearchableSymbol("-[Foo bar:]") == "-[Foo bar:]")
        #expect(demangleSearchableSymbol("__Zinvalid") == "__Zinvalid")
    }

    @Test func symbolTableVisibilityExcludesImportsAndDebugRecords() {
        #expect(searchableSymbolVisibility(flags: .init(rawValue: N_SECT), hasExportTrie: true) == .local)
        #expect(searchableSymbolVisibility(flags: .init(rawValue: N_SECT | N_EXT), hasExportTrie: true) == .local)
        #expect(searchableSymbolVisibility(flags: .init(rawValue: N_SECT | N_EXT), hasExportTrie: false) == .export)
        #expect(searchableSymbolVisibility(flags: .init(rawValue: N_SECT | N_EXT | N_PEXT), hasExportTrie: false) == .local)
        #expect(searchableSymbolVisibility(flags: .init(rawValue: N_UNDF | N_EXT), hasExportTrie: false) == nil)
        #expect(searchableSymbolVisibility(flags: .init(rawValue: N_SO), hasExportTrie: false) == nil)
    }
}

private func symbolMachOFixture() -> Data {
    let names: [(String, UInt8)] = [
        ("_shared", UInt8(N_SECT)),
        ("__Z3fooi", UInt8(N_SECT)),
        ("__Z3fooi", UInt8(N_SECT)),
        ("_imported", UInt8(N_UNDF | N_EXT)),
        ("source.cpp", UInt8(N_SO)),
    ]
    var strings = Data([0])
    var entries = Data()
    for (name, type) in names {
        var entry = nlist_64()
        entry.n_un.n_strx = UInt32(strings.count)
        entry.n_type = type
        entry.n_sect = 1
        entry.n_value = 512
        withUnsafeBytes(of: entry) { entries.append(contentsOf: $0) }
        strings.append(contentsOf: name.utf8)
        strings.append(0)
    }
    let trie = Data([0, 2] + Array("_shared\0".utf8) + [25]
                    + Array("_only_export\0".utf8) + [29, 2, 0, 0, 0, 2, 0, 0, 0])
    var data = Data(count: 8192)
    func put<T>(_ value: T, at offset: Int) {
        var value = value
        withUnsafeBytes(of: &value) { data.replaceSubrange(offset..<(offset + $0.count), with: $0) }
    }
    var header = mach_header_64()
    header.magic = MH_MAGIC_64
    header.cputype = CPU_TYPE_ARM64
    header.cpusubtype = CPU_SUBTYPE_ARM64_ALL
    header.filetype = UInt32(MH_DYLIB)
    header.ncmds = 4
    header.sizeofcmds = UInt32(2 * MemoryLayout<segment_command_64>.size + MemoryLayout<symtab_command>.size + MemoryLayout<linkedit_data_command>.size)
    put(header, at: 0)
    var cursor = MemoryLayout<mach_header_64>.size
    for (name, offset) in [("__TEXT", 0), ("__LINKEDIT", 4096)] {
        var segment = segment_command_64()
        segment.cmd = UInt32(LC_SEGMENT_64)
        segment.cmdsize = UInt32(MemoryLayout<segment_command_64>.size)
        withUnsafeMutableBytes(of: &segment.segname) { $0.copyBytes(from: Array(name.utf8)) }
        segment.vmaddr = UInt64(offset)
        segment.vmsize = 4096
        segment.fileoff = UInt64(offset)
        segment.filesize = 4096
        put(segment, at: cursor)
        cursor += MemoryLayout<segment_command_64>.size
    }
    var symtab = symtab_command()
    symtab.cmd = UInt32(LC_SYMTAB)
    symtab.cmdsize = UInt32(MemoryLayout<symtab_command>.size)
    symtab.symoff = 4096
    symtab.nsyms = UInt32(names.count)
    symtab.stroff = UInt32(4096 + entries.count)
    symtab.strsize = UInt32(strings.count)
    put(symtab, at: cursor)
    cursor += MemoryLayout<symtab_command>.size
    var exports = linkedit_data_command()
    exports.cmd = LC_DYLD_EXPORTS_TRIE
    exports.cmdsize = UInt32(MemoryLayout<linkedit_data_command>.size)
    exports.dataoff = symtab.stroff + symtab.strsize
    exports.datasize = UInt32(trie.count)
    put(exports, at: cursor)
    data.replaceSubrange(4096..<(4096 + entries.count), with: entries)
    data.replaceSubrange(Int(symtab.stroff)..<Int(exports.dataoff), with: strings)
    data.replaceSubrange(Int(exports.dataoff)..<(Int(exports.dataoff) + trie.count), with: trie)
    return data
}
