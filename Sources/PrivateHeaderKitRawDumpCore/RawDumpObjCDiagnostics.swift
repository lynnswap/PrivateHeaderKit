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

final class RawDumpObjCDiagnosticsAccumulator {
    private var retained = Set<PrivateHeaderKitRawDumpDiagnostic>()
    private var omittedDiagnosticCount: UInt = 0

    func append(contentsOf diagnostics: [ObjCProtocolDiagnostic]) {
        for diagnostic in diagnostics {
            let record = privateHeaderKitDiagnostic(from: diagnostic)
            guard !retained.contains(record) else { continue }
            guard retained.count < PrivateHeaderKitRawDumpDiagnosticsReport.maximumDiagnosticCount else {
                omittedDiagnosticCount = omittedDiagnosticCount == UInt.max
                    ? UInt.max
                    : omittedDiagnosticCount + 1
                continue
            }
            retained.insert(record)
        }
    }

    var report: PrivateHeaderKitRawDumpDiagnosticsReport {
        PrivateHeaderKitRawDumpDiagnosticsReport(
            diagnostics: Array(retained),
            omittedDiagnosticCount: omittedDiagnosticCount
        )
    }
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
