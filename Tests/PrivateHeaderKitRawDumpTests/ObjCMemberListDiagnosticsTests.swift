import Foundation
import MachOKit
@_spi(Core) @_spi(Diagnostics) import MachOObjCSection
import PrivateHeaderKitHelperProtocol
import Testing
@testable import PrivateHeaderKitRawDumpCore

struct ObjCMemberListDiagnosticsTests {
    @Test func wholeTableFailureKeepsMemberKindAndOuterOffset() {
        let record = rawDumpMemberListDiagnostic(
            className: "Owner",
            kind: .classMethod,
            outerListOffset: 120,
            location: .table,
            failure: .excessiveElementCount(actual: 65_537, maximum: 65_536)
        )

        #expect(record.owner == "Objective-C class Owner")
        #expect(
            record.degradation
                == "class-method metadata at relative list offset 120"
                    + " could not be fully read: element count 65537"
                    + " exceeds the safety limit 65536"
        )
    }

    @Test func entryFailureIncludesImageIndexOffsetAndTerminalSafeOwner() {
        let record = rawDumpMemberListDiagnostic(
            className: "Owner\nName",
            kind: .instanceProperty,
            outerListOffset: 240,
            location: .entry(index: 2, imageIndex: 1194, offset: 272),
            failure: .misalignedListAddress(address: 4_097, requiredAlignment: 8)
        )

        #expect(record.owner == #"Objective-C class Owner\nName"#)
        #expect(
            record.degradation
                == "instance-property metadata at relative list offset 240"
                    + " entry 2 (cache image index 1194, offset 272)"
                    + " could not be fully read: member list address 4097"
                    + " is not aligned to 8 bytes"
        )
    }

    @Test func memberAndProtocolDiagnosticsShareBoundedWireReport() throws {
        let fixture = try InvalidMemberListFixture(
            memberDiagnosticCount: PrivateHeaderKitRawDumpDiagnosticsReport.maximumDiagnosticCount
        )
        let accumulator = RawDumpObjCDiagnosticsAccumulator()
        let protocolDiagnostics = fixture.objcProtocol.readInfo(
            in: fixture.machO
        ).diagnostics
        #expect(protocolDiagnostics.count == 1)
        accumulator.append(contentsOf: protocolDiagnostics)
        accumulator.append(contentsOf: protocolDiagnostics)

        let memberDiagnostics = fixture.objcClass.readInfo(
            in: fixture.machO
        ).memberListDiagnostics
        #expect(
            memberDiagnostics.count
                == PrivateHeaderKitRawDumpDiagnosticsReport.maximumDiagnosticCount
        )
        accumulator.append(contentsOf: memberDiagnostics)

        let report = accumulator.report
        #expect(
            report.diagnostics.count
                == PrivateHeaderKitRawDumpDiagnosticsReport.maximumDiagnosticCount
        )
        #expect(report.omittedDiagnosticCount == 1)
        #expect(
            report.diagnostics.count {
                $0.owner.hasPrefix("Objective-C protocol")
            } == 1
        )
        #expect(
            report.diagnostics.count {
                $0.owner.hasPrefix("Objective-C class")
            } == PrivateHeaderKitRawDumpDiagnosticsReport.maximumDiagnosticCount - 1
        )

        let encoded = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(
            PrivateHeaderKitRawDumpDiagnosticsReport.self,
            from: encoded
        )
        #expect(decoded == report)
    }
}

private final class InvalidMemberListFixture {
    let machO: MachOFile
    let objcClass: ObjCClass64
    let objcProtocol: ObjCProtocol64
    private let url: URL

    init(memberDiagnosticCount: Int) throws {
        let fileSize = 0x4000
        let vmAddress: UInt64 = 0x1_0000_0000
        let classOffset = 0x400
        let metaClassOffset = 0x480
        let classROOffset = 0x500
        let metaClassROOffset = 0x580
        let memberListOffset = 0x800
        let classNameOffset = 0x1800
        let protocolNameOffset = 0x1840
        let outerStride = MemoryLayout<RelativeListListEntry.Layout>.size
        var data = Data(count: fileSize)

        var header = mach_header_64()
        header.magic = UInt32(MH_MAGIC_64)
        header.cputype = CPU_TYPE_ARM64
        header.cpusubtype = CPU_SUBTYPE_ARM64_ALL
        header.filetype = UInt32(MH_DYLIB)
        header.ncmds = 1
        header.sizeofcmds = UInt32(MemoryLayout<segment_command_64>.size)
        data.storeValue(header, at: 0)

        var segment = segment_command_64()
        segment.cmd = UInt32(LC_SEGMENT_64)
        segment.cmdsize = UInt32(MemoryLayout<segment_command_64>.size)
        segment.vmaddr = vmAddress
        segment.vmsize = UInt64(fileSize)
        segment.filesize = UInt64(fileSize)
        segment.maxprot = VM_PROT_READ
        segment.initprot = VM_PROT_READ
        data.storeValue(segment, at: MemoryLayout<mach_header_64>.size)

        func address(_ offset: Int) -> UInt64 {
            vmAddress + UInt64(offset)
        }

        data.storeCString("MemberOwner", at: classNameOffset)
        data.storeCString("ProtocolOwner", at: protocolNameOffset)
        data.storeValue(
            RawEntrySizeListHeader(
                entsizeAndFlags: UInt32(outerStride),
                count: UInt32(memberDiagnosticCount)
            ),
            at: memberListOffset
        )
        for index in 0..<memberDiagnosticCount {
            let entryOffset = memberListOffset
                + MemoryLayout<EntrySizeListHeader>.size
                + index * outerStride
            var entry = RelativeListListEntry.Layout()
            entry.imageIndex = 0
            entry.listOffset = Int64(fileSize + 0x100 + index * 8 - entryOffset)
            data.storeValue(entry, at: entryOffset)
        }

        data.storeValue(
            RawClassROData64(
                flags: 0,
                instanceStart: 0,
                instanceSize: 0,
                _reserved: 0,
                ivarLayout: 0,
                name: address(classNameOffset),
                baseMethods: address(memberListOffset) | 1,
                baseProtocols: 0,
                ivars: 0,
                weakIvarLayout: 0,
                baseProperties: 0
            ),
            at: classROOffset
        )
        data.storeValue(
            RawClassROData64(
                flags: 0,
                instanceStart: 0,
                instanceSize: 0,
                _reserved: 0,
                ivarLayout: 0,
                name: address(classNameOffset),
                baseMethods: 0,
                baseProtocols: 0,
                ivars: 0,
                weakIvarLayout: 0,
                baseProperties: 0
            ),
            at: metaClassROOffset
        )

        data.storeValue(
            RawClass64(
                isa: address(metaClassOffset),
                superclass: 0,
                methodCacheBuckets: 0,
                methodCacheProperties: 0,
                dataVMAddrAndFastFlags: address(classROOffset),
                swiftClassFlags: 0
            ),
            at: classOffset
        )
        data.storeValue(
            RawClass64(
                isa: address(metaClassOffset),
                superclass: 0,
                methodCacheBuckets: 0,
                methodCacheProperties: 0,
                dataVMAddrAndFastFlags: address(metaClassROOffset),
                swiftClassFlags: 0
            ),
            at: metaClassOffset
        )

        let classLayout = data.loadValue(
            ObjCClass64.Layout.self,
            at: classOffset
        )
        let protocolLayout = data.loadValue(
            ObjCProtocol64.Layout.self,
            from: RawProtocol64(
                isa: 0,
                mangledName: address(protocolNameOffset),
                protocols: 0,
                instanceMethods: 0,
                classMethods: 0,
                optionalInstanceMethods: 0,
                optionalClassMethods: 0,
                instanceProperties: 0,
                size: UInt32(MemoryLayout<ObjCProtocol64.Layout>.size),
                flags: 0,
                extendedMethodTypes: 0,
                demangledName: 0,
                classProperties: 0
            )
        )

        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PrivateHeaderKitInvalidMemberList-\(UUID().uuidString)"
        )
        try data.write(to: url)
        machO = try MachOFile(url: url)
        objcClass = ObjCClass64(layout: classLayout, offset: classOffset)
        objcProtocol = ObjCProtocol64(layout: protocolLayout, offset: -1)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private struct RawEntrySizeListHeader {
    let entsizeAndFlags: UInt32
    let count: UInt32
}

private struct RawClassROData64 {
    let flags: UInt32
    let instanceStart: UInt32
    let instanceSize: UInt32
    let reserved: UInt32
    let ivarLayout: UInt64
    let name: UInt64
    let baseMethods: UInt64
    let baseProtocols: UInt64
    let ivars: UInt64
    let weakIvarLayout: UInt64
    let baseProperties: UInt64

    init(
        flags: UInt32,
        instanceStart: UInt32,
        instanceSize: UInt32,
        _reserved: UInt32,
        ivarLayout: UInt64,
        name: UInt64,
        baseMethods: UInt64,
        baseProtocols: UInt64,
        ivars: UInt64,
        weakIvarLayout: UInt64,
        baseProperties: UInt64
    ) {
        self.flags = flags
        self.instanceStart = instanceStart
        self.instanceSize = instanceSize
        self.reserved = _reserved
        self.ivarLayout = ivarLayout
        self.name = name
        self.baseMethods = baseMethods
        self.baseProtocols = baseProtocols
        self.ivars = ivars
        self.weakIvarLayout = weakIvarLayout
        self.baseProperties = baseProperties
    }
}

private struct RawClass64 {
    let isa: UInt64
    let superclass: UInt64
    let methodCacheBuckets: UInt64
    let methodCacheProperties: UInt64
    let dataVMAddrAndFastFlags: UInt64
    let swiftClassFlags: UInt32
}

private struct RawProtocol64 {
    let isa: UInt64
    let mangledName: UInt64
    let protocols: UInt64
    let instanceMethods: UInt64
    let classMethods: UInt64
    let optionalInstanceMethods: UInt64
    let optionalClassMethods: UInt64
    let instanceProperties: UInt64
    let size: UInt32
    let flags: UInt32
    let extendedMethodTypes: UInt64
    let demangledName: UInt64
    let classProperties: UInt64
}

private extension Data {
    func loadValue<Value>(_ type: Value.Type, at offset: Int) -> Value {
        self[offset..<(offset + MemoryLayout<Value>.size)].withUnsafeBytes {
            $0.loadUnaligned(as: type)
        }
    }

    func loadValue<Value, Raw>(_ type: Value.Type, from raw: Raw) -> Value {
        precondition(MemoryLayout<Value>.size == MemoryLayout<Raw>.size)
        return Swift.withUnsafeBytes(of: raw) {
            $0.loadUnaligned(as: type)
        }
    }

    mutating func storeValue<Value>(_ value: Value, at offset: Int) {
        Swift.withUnsafeBytes(of: value) { bytes in
            replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
    }

    mutating func storeCString(_ value: String, at offset: Int) {
        let bytes = Array(value.utf8) + [0]
        replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }
}
