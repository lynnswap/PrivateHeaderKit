import Foundation
@_spi(Diagnostics) import MachOObjCSection
import PrivateHeaderKitHelperProtocol

enum RawDumpObjCMetadataKind: Equatable, Sendable {
    case `class`
    case `protocol`
    case category
}

enum RawDumpObjCProtocolReadPolicy: Equatable, Sendable {
    case headerDump
    case directProtocolNames
}

func rawDumpObjCProtocolReadPolicy(
    for kind: RawDumpObjCMetadataKind
) -> RawDumpObjCProtocolReadPolicy {
    switch kind {
    case .class, .category:
        .headerDump
    case .protocol:
        .directProtocolNames
    }
}

func rawDumpObjCInfoOptions(for kind: RawDumpObjCMetadataKind) -> ObjCInfoOptions {
    switch rawDumpObjCProtocolReadPolicy(for: kind) {
    case .headerDump:
        .headerDump
    case .directProtocolNames:
        ObjCInfoOptions(protocolInfoOptions: .directProtocolNames)
    }
}

func rawDumpObjCProtocolInfoOptions(
    for kind: RawDumpObjCMetadataKind
) -> ObjCProtocolInfoOptions {
    switch rawDumpObjCProtocolReadPolicy(for: kind) {
    case .headerDump, .directProtocolNames:
        .directProtocolNames
    }
}

private struct RawDumpObjCDiagnosticChannel {
    private(set) var records: [PrivateHeaderKitRawDumpDiagnostic] = []
    private var seen = Set<PrivateHeaderKitRawDumpDiagnostic>()
    private(set) var omittedObservationCount: UInt = 0

    mutating func append(_ record: PrivateHeaderKitRawDumpDiagnostic) {
        guard !seen.contains(record) else { return }
        // Do not retain identities beyond the wire cap: that would make malformed-target
        // memory unbounded. Repeated cap-excluded records count as omitted observations;
        // global uniqueness beyond the retained window is intentionally not claimed.
        guard records.count < PrivateHeaderKitRawDumpDiagnosticsReport.maximumDiagnosticCount
        else {
            omittedObservationCount = saturatingSum(omittedObservationCount, 1)
            return
        }
        seen.insert(record)
        records.append(record)
    }

    func contains(_ record: PrivateHeaderKitRawDumpDiagnostic) -> Bool {
        seen.contains(record)
    }
}

final class RawDumpObjCDiagnosticsAccumulator {
    private var fieldDiagnostics = RawDumpObjCDiagnosticChannel()
    private var protocolDiagnostics = RawDumpObjCDiagnosticChannel()
    private var memberDiagnostics = RawDumpObjCDiagnosticChannel()

    func append<Value>(contentsOf result: ObjCMetadataReadResult<Value>) {
        append(contentsOf: result.fieldDiagnostics)
        append(contentsOf: result.diagnostics)
        append(contentsOf: result.memberListDiagnostics)
        append(contentsOf: result.tableDiagnostics)
    }

    func append(contentsOf diagnostics: [ObjCMetadataFieldDiagnostic]) {
        for diagnostic in diagnostics {
            fieldDiagnostics.append(privateHeaderKitDiagnostic(from: diagnostic))
        }
    }

    func append(contentsOf diagnostics: [ObjCProtocolDiagnostic]) {
        for diagnostic in diagnostics {
            protocolDiagnostics.append(privateHeaderKitDiagnostic(from: diagnostic))
        }
    }

    func append(contentsOf diagnostics: [ObjCMemberListDiagnostic]) {
        for diagnostic in diagnostics {
            memberDiagnostics.append(privateHeaderKitDiagnostic(from: diagnostic))
        }
    }

    func append(contentsOf diagnostics: [ObjCMetadataTableDiagnostic]) {
        for diagnostic in diagnostics {
            memberDiagnostics.append(privateHeaderKitDiagnostic(from: diagnostic))
        }
    }

    var report: PrivateHeaderKitRawDumpDiagnosticsReport {
        var selected: [PrivateHeaderKitRawDumpDiagnostic] = []
        selected.reserveCapacity(PrivateHeaderKitRawDumpDiagnosticsReport.maximumDiagnosticCount)
        var omittedDiagnosticCount = saturatingSum(
            fieldDiagnostics.omittedObservationCount,
            protocolDiagnostics.omittedObservationCount
        )
        omittedDiagnosticCount = saturatingSum(
            omittedDiagnosticCount,
            memberDiagnostics.omittedObservationCount
        )

        func select(_ record: PrivateHeaderKitRawDumpDiagnostic) {
            if selected.count < PrivateHeaderKitRawDumpDiagnosticsReport.maximumDiagnosticCount {
                selected.append(record)
            } else {
                omittedDiagnosticCount = saturatingSum(omittedDiagnosticCount, 1)
            }
        }

        for record in fieldDiagnostics.records {
            select(record)
        }
        for record in protocolDiagnostics.records
        where !fieldDiagnostics.contains(record) {
            select(record)
        }
        for record in memberDiagnostics.records
        where !fieldDiagnostics.contains(record)
            && !protocolDiagnostics.contains(record) {
            select(record)
        }

        return PrivateHeaderKitRawDumpDiagnosticsReport(
            diagnostics: selected,
            omittedDiagnosticCount: omittedDiagnosticCount
        )
    }
}

private func saturatingSum(_ lhs: UInt, _ rhs: UInt) -> UInt {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? UInt.max : sum
}

func writeRawDumpDiagnosticsReport(
    _ report: PrivateHeaderKitRawDumpDiagnosticsReport,
    to reportURL: URL
) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(report)
    guard data.count <= PrivateHeaderKitRawDumpDiagnosticsReport.maximumEncodedByteCount else {
        throw CocoaError(.fileWriteOutOfSpace)
    }
    try data.write(to: reportURL, options: .atomic)
}

private func privateHeaderKitDiagnostic(
    from diagnostic: ObjCProtocolDiagnostic
) -> PrivateHeaderKitRawDumpDiagnostic {
    switch diagnostic {
    case .unreadableList(let unreadable):
        let path = protocolPathDescription(unreadable.protocolPath)
        return PrivateHeaderKitRawDumpDiagnostic(
            owner: subjectDescription(unreadable.subject),
            degradation:
                "adopted-protocol metadata at list offset \(unreadable.listOffset)"
                + " could not be fully read\(path): \(failureDescription(unreadable.failure))"
        )
    case .cycle(let cycle):
        return PrivateHeaderKitRawDumpDiagnostic(
            owner: subjectDescription(cycle.subject),
            degradation:
                "adopted-protocol traversal stopped at cycle"
                + protocolPathDescription(cycle.protocolPath)
        )
    case .recursionLimit(let limit):
        return PrivateHeaderKitRawDumpDiagnostic(
            owner: subjectDescription(limit.subject),
            degradation:
                "adopted-protocol traversal stopped at the \(limit.maximumDepth)-edge safety limit"
                + protocolPathDescription(limit.protocolPath)
        )
    case .invalidIdentity(let invalid):
        return PrivateHeaderKitRawDumpDiagnostic(
            owner: subjectDescription(invalid.subject),
            degradation:
                "adopted protocols were not traversed because protocol offset"
                + " \(invalid.protocolOffset) has no stable identity"
        )
    }
}

private func privateHeaderKitDiagnostic(
    from diagnostic: ObjCMetadataFieldDiagnostic
) -> PrivateHeaderKitRawDumpDiagnostic {
    switch diagnostic {
    case .classROData(let classROData):
        rawDumpClassRODataDiagnostic(
            subject: classROData.subject,
            role: classROData.role,
            classObjectOffset: classROData.classObjectOffset,
            failure: classROData.failure
        )
    case .ivarOffset(let ivarOffset):
        rawDumpIvarOffsetDiagnostic(
            subject: ivarOffset.subject,
            index: ivarOffset.index,
            name: ivarOffset.name,
            failure: ivarOffset.failure
        )
    }
}

func rawDumpClassRODataDiagnostic(
    subject: ObjCMetadataFieldDiagnostic.Subject,
    role: ObjCMetadataFieldDiagnostic.ClassRole,
    classObjectOffset: Int,
    failure: ObjCMetadataFieldDiagnostic.Failure
) -> PrivateHeaderKitRawDumpDiagnostic {
    PrivateHeaderKitRawDumpDiagnostic(
        owner: subjectDescription(subject),
        degradation:
            "\(classRoleDescription(role)) at class object offset \(classObjectOffset)"
            + " could not be read: \(failureDescription(failure))"
    )
}

func rawDumpIvarOffsetDiagnostic(
    subject: ObjCMetadataFieldDiagnostic.Subject,
    index: Int,
    name: String,
    failure: ObjCMetadataFieldDiagnostic.Failure
) -> PrivateHeaderKitRawDumpDiagnostic {
    PrivateHeaderKitRawDumpDiagnostic(
        owner: subjectDescription(subject),
        degradation:
            "ivar-offset metadata for ivar index \(index)"
            + " could not be read: \(failureDescription(failure))"
            + "; name \(boundedMetadataString(name))"
    )
}

private func privateHeaderKitDiagnostic(
    from diagnostic: ObjCMemberListDiagnostic
) -> PrivateHeaderKitRawDumpDiagnostic {
    rawDumpMemberListDiagnostic(
        className: diagnostic.className,
        kind: diagnostic.kind,
        outerListOffset: diagnostic.outerListOffset,
        location: diagnostic.location,
        failure: diagnostic.failure
    )
}

private func privateHeaderKitDiagnostic(
    from diagnostic: ObjCMetadataTableDiagnostic
) -> PrivateHeaderKitRawDumpDiagnostic {
    rawDumpMetadataTableDiagnostic(
        owner: diagnostic.owner,
        site: diagnostic.site,
        failure: diagnostic.failure
    )
}

private func rawDumpMetadataTableDiagnostic(
    owner: ObjCMetadataTableDiagnostic.Owner,
    site: ObjCMetadataTableDiagnostic.Site,
    failure: ObjCMetadataTableDiagnostic.Failure
) -> PrivateHeaderKitRawDumpDiagnostic {
    let ownerDescription: String
    let metadataDescription: String
    switch owner {
    case let .member(subject, kind):
        ownerDescription = subjectDescription(subject)
        metadataDescription = "\(metadataTableMemberKindDescription(kind)) metadata table"
    case let .loadedImageRoot(section, pointerWidth):
        ownerDescription = "Objective-C loaded-image roots"
        metadataDescription =
            "\(pointerWidthDescription(pointerWidth))"
            + " \(rootSectionDescription(section)) root table"
    case let .loadedRelationship(subject, role):
        ownerDescription = subjectDescription(subject)
        metadataDescription = "\(loadedRelationshipDescription(role)) relationship"
    }

    return PrivateHeaderKitRawDumpDiagnostic(
        owner: ownerDescription,
        degradation:
            "\(metadataDescription)\(metadataTableSiteDescription(site))"
            + " could not be fully read: \(failureDescription(failure))"
    )
}

func rawDumpMemberListDiagnostic(
    className: String,
    kind: ObjCMemberListDiagnostic.Kind,
    outerListOffset: Int,
    location: ObjCMemberListDiagnostic.Location,
    failure: ObjCMemberListDiagnostic.Failure
) -> PrivateHeaderKitRawDumpDiagnostic {
    PrivateHeaderKitRawDumpDiagnostic(
        owner: "Objective-C class \(boundedMetadataString(className))",
        degradation:
            "\(memberKindDescription(kind)) metadata at relative list offset \(outerListOffset)"
            + memberLocationDescription(location)
            + " could not be fully read: \(failureDescription(failure))"
    )
}

private func memberKindDescription(_ kind: ObjCMemberListDiagnostic.Kind) -> String {
    switch kind {
    case .instanceMethod: "instance-method"
    case .classMethod: "class-method"
    case .instanceProperty: "instance-property"
    case .classProperty: "class-property"
    }
}

private func metadataTableMemberKindDescription(
    _ kind: ObjCMetadataTableDiagnostic.MemberKind
) -> String {
    switch kind {
    case .ivar: "ivar"
    case .instanceMethod: "instance-method"
    case .classMethod: "class-method"
    case .optionalInstanceMethod: "optional-instance-method"
    case .optionalClassMethod: "optional-class-method"
    case .instanceProperty: "instance-property"
    case .classProperty: "class-property"
    }
}

private func rootSectionDescription(
    _ section: ObjCMetadataTableDiagnostic.LoadedImageRootSection
) -> String {
    switch section {
    case .classList: "class-list"
    case .nonLazyClassList: "non-lazy-class-list"
    case .protocolList: "protocol-list"
    case .categoryList: "category-list"
    case .nonLazyCategoryList: "non-lazy-category-list"
    case .categoryList2: "category-list-2"
    }
}

private func pointerWidthDescription(
    _ pointerWidth: ObjCMetadataTableDiagnostic.PointerWidth
) -> String {
    switch pointerWidth {
    case .bits32: "32-bit"
    case .bits64: "64-bit"
    }
}

private func loadedRelationshipDescription(
    _ role: ObjCMetadataTableDiagnostic.LoadedRelationshipRole
) -> String {
    switch role {
    case .metaclass: "metaclass"
    case .superclass: "superclass"
    case .categoryClass: "category-class"
    case .categoryStubClass: "category-stub-class"
    }
}

private func metadataTableSiteDescription(
    _ site: ObjCMetadataTableDiagnostic.Site
) -> String {
    switch site {
    case .table(let provenance), .relationship(let provenance):
        provenanceDescription(provenance)
    case let .entry(index, provenance):
        " entry \(index)\(provenanceDescription(provenance))"
    }
}

private func provenanceDescription(
    _ provenance: ObjCMetadataTableDiagnostic.Provenance
) -> String {
    var coordinates: [String] = []
    if let logicalOffset = provenance.logicalOffset {
        coordinates.append("logical offset \(logicalOffset)")
    }
    if let fileOffset = provenance.fileOffset {
        coordinates.append("file offset \(fileOffset)")
    }
    if let imageAddress = provenance.imageAddress {
        coordinates.append("image address \(imageAddress)")
    }
    guard !coordinates.isEmpty else { return "" }
    return " (\(coordinates.joined(separator: ", ")))"
}

private func memberLocationDescription(
    _ location: ObjCMemberListDiagnostic.Location
) -> String {
    switch location {
    case .table:
        return ""
    case let .entry(index, imageIndex, offset):
        return " entry \(index) (cache image index \(imageIndex), offset \(offset))"
    }
}

private func subjectDescription(_ subject: ObjCProtocolDiagnostic.Subject) -> String {
    switch subject {
    case .class(let name):
        "Objective-C class \(boundedMetadataString(name))"
    case .protocol(let name):
        "Objective-C protocol \(boundedMetadataString(name))"
    case .category(let className, let name):
        "Objective-C category \(boundedMetadataString(className))(\(boundedMetadataString(name)))"
    }
}

private func subjectDescription(_ subject: ObjCMetadataFieldDiagnostic.Subject) -> String {
    switch subject {
    case .namedClass(let name, let objectOffset):
        "Objective-C class object at offset \(objectOffset)"
            + " named \(boundedMetadataString(name))"
    case .classObject(let offset):
        "Objective-C class object at offset \(offset)"
    }
}

private func subjectDescription(
    _ subject: ObjCMetadataTableDiagnostic.MetadataSubject
) -> String {
    switch subject {
    case .class(let name):
        "Objective-C class \(boundedMetadataString(name))"
    case .protocol(let name):
        "Objective-C protocol \(boundedMetadataString(name))"
    case let .category(className, name):
        "Objective-C category \(boundedMetadataString(className))"
            + "(\(boundedMetadataString(name)))"
    }
}

private func classRoleDescription(
    _ role: ObjCMetadataFieldDiagnostic.ClassRole
) -> String {
    switch role {
    case .instance:
        "instance class RO data"
    case .metaclass:
        "metaclass RO data"
    }
}

private func boundedMetadataString(_ value: String) -> String {
    PrivateHeaderKitRawDumpDiagnostic(owner: value, degradation: "unused").owner
}

private func protocolPathDescription(_ path: [String]) -> String {
    guard !path.isEmpty else { return "" }
    var result = " along path "
    for name in path {
        let safeName = boundedMetadataString(name)
        let separator = result == " along path " ? "" : " -> "
        guard result.utf8.count + separator.utf8.count + safeName.utf8.count
                <= PrivateHeaderKitRawDumpDiagnostic.maximumStringUTF8Count
        else {
            result += " -> …"
            break
        }
        result += separator + safeName
    }
    return result
}

private func failureDescription(
    _ failure: ObjCProtocolDiagnostic.UnreadableList.Failure
) -> String {
    switch failure {
    case .unsupportedListEncoding:
        "list encoding is unsupported by this reader"
    case .invalidListOffset(let offset):
        "list offset \(offset) is not a readable nonnegative address"
    case .invalidElementCount(let count):
        "element count \(count) cannot be represented"
    case .invalidSignedElementCount(let count):
        "signed element count \(count) is negative"
    case .excessiveElementCount(let actual, let maximum):
        "element count \(actual) exceeds the safety limit \(maximum)"
    case .excessiveByteCount(let actual, let maximum):
        "table size \(actual) bytes exceeds the safety limit \(maximum)"
    case .unresolvedListPointer:
        "list pointer could not be rebased or canonicalized"
    case .missingListBackingData:
        "list pointer has no readable backing data"
    case .unreadableFileHeader(let offset, let byteCount):
        "file header at offset \(offset) is not readable for \(byteCount) bytes"
    case .unreadableImageHeader(let address, let byteCount):
        "image header at address \(address) is not readable for \(byteCount) bytes"
    case .invalidRelativeEntrySize(let advertised, let minimum):
        "relative entry size \(advertised) is smaller than \(minimum)"
    case .invalidRelativeListLocation:
        "relative list location could not be mapped"
    case .relativeImageUnavailable(let imageIndex):
        "cache image index \(imageIndex) is unavailable"
    case .byteCountOverflow(let elementCount, let elementSize):
        "byte count overflowed for \(elementCount) elements of size \(elementSize)"
    case .rangeOverflow(let startOffset, let byteCount):
        "range overflowed from offset \(startOffset) for \(byteCount) bytes"
    case .unreadableFileRange(let offset, let byteCount):
        "file range at offset \(offset) is not readable for \(byteCount) bytes"
    case .unreadableImageRange(let address, let byteCount):
        "image range at address \(address) is not readable for \(byteCount) bytes"
    case .unresolvedRebase(let entryIndex):
        "entry \(entryIndex) could not be rebased"
    case .invalidEntryOffset(let entryIndex):
        "entry \(entryIndex) has an overflowing field offset"
    case .invalidPointer(let entryIndex):
        "entry \(entryIndex) does not identify a loaded protocol"
    case .invalidIdentity(let entryIndex):
        "entry \(entryIndex) has no stable protocol identity"
    case .missingBackingData(let entryIndex):
        "entry \(entryIndex) has no backing data"
    case .unreadableFileLayout(let entryIndex, let offset, let byteCount):
        "entry \(entryIndex) layout at file offset \(offset) is not readable for \(byteCount) bytes"
    case .unreadableImageLayout(let entryIndex, let address, let byteCount):
        "entry \(entryIndex) layout at image address \(address) is not readable for \(byteCount) bytes"
    }
}

private func failureDescription(
    _ failure: ObjCMemberListDiagnostic.Failure
) -> String {
    switch failure {
    case .unsupportedListEncoding:
        "list encoding is unsupported by this reader"
    case .invalidListOffset(let offset):
        "list offset \(offset) is not a readable nonnegative address"
    case .invalidElementCount(let count):
        "element count \(count) cannot be represented"
    case .invalidSignedElementCount(let count):
        "signed element count \(count) is negative"
    case .excessiveElementCount(let actual, let maximum):
        "element count \(actual) exceeds the safety limit \(maximum)"
    case .excessiveByteCount(let actual, let maximum):
        "table size \(actual) bytes exceeds the safety limit \(maximum)"
    case .invalidRelativeEntrySize(let advertised, let minimum):
        "relative entry size \(advertised) is smaller than \(minimum)"
    case .invalidListEntrySize(let advertised, let expected):
        "member entry size \(advertised) does not match expected size \(expected)"
    case .misalignedListOffset(let offset, let alignment):
        "member list offset \(offset) is not aligned to \(alignment) bytes"
    case .misalignedListAddress(let address, let alignment):
        "member list address \(address) is not aligned to \(alignment) bytes"
    case .unresolvedListPointer:
        "list pointer could not be rebased or canonicalized"
    case .missingListBackingData:
        "list pointer has no readable backing data"
    case .unreadableFileHeader(let offset, let byteCount):
        "file header at offset \(offset) is not readable for \(byteCount) bytes"
    case .unreadableImageHeader(let address, let byteCount):
        "image header at address \(address) is not readable for \(byteCount) bytes"
    case .invalidRelativeListLocation:
        "relative list location could not be mapped"
    case .relativeImageUnavailable(let imageIndex):
        "cache image index \(imageIndex) is unavailable"
    case .byteCountOverflow(let elementCount, let elementSize):
        "byte count overflowed for \(elementCount) elements of size \(elementSize)"
    case .rangeOverflow(let startOffset, let byteCount):
        "range overflowed from offset \(startOffset) for \(byteCount) bytes"
    case .unreadableFileRange(let offset, let byteCount):
        "file range at offset \(offset) is not readable for \(byteCount) bytes"
    case .unreadableImageRange(let address, let byteCount):
        "image range at address \(address) is not readable for \(byteCount) bytes"
    }
}

private func failureDescription(
    _ failure: ObjCMetadataFieldDiagnostic.Failure
) -> String {
    switch failure {
    case .unresolvedRebase:
        "field pointer could not be rebased"
    case .missingBackingData:
        "field pointer has no readable backing data"
    case .unreadableFileRange(let offset, let byteCount):
        "file range at offset \(offset) is not readable for \(byteCount) bytes"
    case .unreadableImageRange(let address, let byteCount):
        "image range at address \(address) is not readable for \(byteCount) bytes"
    }
}

private func failureDescription(
    _ failure: ObjCMetadataTableDiagnostic.Failure
) -> String {
    switch failure {
    case .unsupportedListEncoding:
        "list encoding is unsupported by this reader"
    case .invalidListOffset(let offset):
        "list offset \(offset) is not a readable address"
    case .invalidElementCount(let count):
        "element count \(count) cannot be represented"
    case .invalidSignedElementCount(let count):
        "signed element count \(count) is negative"
    case .invalidElementStride(let stride):
        "element stride \(stride) cannot be represented"
    case let .elementStrideTooSmall(advertised, minimum):
        "element stride \(advertised) is smaller than \(minimum)"
    case let .unexpectedElementStride(advertised, expected):
        "element stride \(advertised) does not match expected size \(expected)"
    case let .misalignedTableOffset(offset, requiredAlignment):
        "table offset \(offset) is not aligned to \(requiredAlignment) bytes"
    case let .misalignedTableAddress(address, requiredAlignment):
        "table address \(address) is not aligned to \(requiredAlignment) bytes"
    case let .excessiveElementCount(actual, maximum):
        "element count \(actual) exceeds the safety limit \(maximum)"
    case let .excessiveByteCount(actual, maximum):
        "table size \(actual) bytes exceeds the safety limit \(maximum)"
    case let .byteCountOverflow(elementCount, elementSize):
        "byte count overflowed for \(elementCount) elements of size \(elementSize)"
    case let .rangeOverflow(startOffset, byteCount):
        "range overflowed from offset \(startOffset) for \(byteCount) bytes"
    case let .unreadableFileRange(offset, byteCount):
        "file range at offset \(offset) is not readable for \(byteCount) bytes"
    case let .unreadableImageRange(address, byteCount):
        "image range at address \(address) is not readable for \(byteCount) bytes"
    case .invalidFileListOffset(let offset):
        "file list offset \(offset) cannot be represented"
    case .unresolvedListPointer:
        "list pointer could not be rebased"
    case .missingListBackingData:
        "list pointer has no readable backing data"
    case let .unreadableFileHeader(offset, byteCount):
        "file header at offset \(offset) is not readable for \(byteCount) bytes"
    case .invalidEntryLogicalOffset:
        "entry logical offset overflowed"
    case .invalidMethodImplementationOffset:
        "method implementation offset overflowed"
    case .invalidRelativeDisplacement:
        "relative field displacement overflowed"
    case let .invalidSectionByteCount(byteCount, pointerSize):
        "section size \(byteCount) is not a multiple of pointer size \(pointerSize)"
    case let .invalidSectionCoordinates(
        sectionAddress,
        sectionSize,
        sectionFileOffset,
        segmentAddress,
        segmentSize,
        segmentFileOffset,
        segmentFileSize
    ):
        "section coordinates (address \(sectionAddress), size \(sectionSize),"
            + " file offset \(sectionFileOffset)) are outside segment coordinates"
            + " (address \(segmentAddress), size \(segmentSize),"
            + " file offset \(segmentFileOffset), file size \(segmentFileSize))"
    case .missingImageBaseSegment:
        "the loaded image has no __TEXT base segment"
    case let .invalidLoadedSectionAddress(
        imageBase,
        imageVirtualMemoryAddress,
        sectionAddress
    ):
        "section address \(sectionAddress) cannot be mapped from image base"
            + " \(imageBase) and image virtual address \(imageVirtualMemoryAddress)"
    case .invalidPointer(let rawValue):
        "pointer value \(rawValue) is not a readable address"
    case .missingReferencedImage(let address):
        "address \(address) does not belong to an available loaded image"
    case let .unreadableReferencedLayout(address, byteCount):
        "referenced layout at image address \(address)"
            + " is not readable for \(byteCount) bytes"
    case let .invalidEntryArithmetic(baseAddress, targetAddress):
        "target address \(targetAddress) cannot be represented relative"
            + " to base address \(baseAddress)"
    }
}
