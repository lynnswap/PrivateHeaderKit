@_spi(Diagnostics) import MachOObjCSection
import PrivateHeaderKitHelperProtocol
import Testing
@testable import PrivateHeaderKitRawDumpCore

struct ObjCMetadataFieldDiagnosticsTests {
    @Test func namedInstanceClassROFileFailureKeepsStableOffsetAndEscapesName() {
        let record = rawDumpClassRODataDiagnostic(
            subject: .namedClass(name: "Owner\nName", objectOffset: 1_024),
            role: .instance,
            classObjectOffset: 1_024,
            failure: .unreadableFileRange(offset: 16_382, byteCount: 72)
        )

        #expect(
            record.owner
                == #"Objective-C class object at offset 1024 named Owner\nName"#
        )
        #expect(
            record.degradation
                == "instance class RO data at class object offset 1024"
                    + " could not be read: file range at offset 16382"
                    + " is not readable for 72 bytes"
        )
    }

    @Test func unnamedMetaclassROImageFailureUsesFailedMetaclassOffset() {
        let record = rawDumpClassRODataDiagnostic(
            subject: .classObject(offset: 1_024),
            role: .metaclass,
            classObjectOffset: 2_048,
            failure: .unreadableImageRange(address: 32_766, byteCount: 72)
        )

        #expect(record.owner == "Objective-C class object at offset 1024")
        #expect(
            record.degradation
                == "metaclass RO data at class object offset 2048"
                    + " could not be read: image range at address 32766"
                    + " is not readable for 72 bytes"
        )
    }

    @Test func ivarOffsetFailureKeepsIndexNameAndPointerFailure() {
        let subject = ObjCMetadataFieldDiagnostic.Subject.namedClass(
            name: "Owner",
            objectOffset: 1_024
        )
        let cases: [(ObjCMetadataFieldDiagnostic.Failure, String)] = [
            (.unresolvedRebase, "field pointer could not be rebased"),
            (.missingBackingData, "field pointer has no readable backing data"),
        ]

        for (failure, failureDescription) in cases {
            let record = rawDumpIvarOffsetDiagnostic(
                subject: subject,
                index: 2,
                name: "_value\tfield",
                failure: failure
            )

            #expect(
                record.owner
                    == "Objective-C class object at offset 1024 named Owner"
            )
            #expect(
                record.degradation
                    == #"ivar-offset metadata for ivar index 2 named _value\tfield"#
                        + " could not be read: \(failureDescription)"
            )
        }
    }

    @Test func longNamedSubjectCannotDisplaceStableObjectOffset() {
        let record = rawDumpClassRODataDiagnostic(
            subject: .namedClass(
                name: String(repeating: "x", count: 3_000),
                objectOffset: 4_096
            ),
            role: .instance,
            classObjectOffset: 4_096,
            failure: .unresolvedRebase
        )

        #expect(
            record.owner.hasPrefix(
                "Objective-C class object at offset 4096 named "
            )
        )
        #expect(
            record.owner.utf8.count
                == PrivateHeaderKitRawDumpDiagnostic.maximumStringUTF8Count
        )
    }
}
