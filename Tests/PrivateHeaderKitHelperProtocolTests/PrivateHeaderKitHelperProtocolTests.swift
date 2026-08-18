import Foundation
import Testing

@testable import PrivateHeaderKitHelperProtocol

@Suite
struct PrivateHeaderKitHelperProtocolTests {
    @Test func rawDumpDiagnosticsZeroReportRoundTrips() throws {
        let report = PrivateHeaderKitRawDumpDiagnosticsReport(diagnostics: [])
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(
            PrivateHeaderKitRawDumpDiagnosticsReport.self,
            from: data
        )

        #expect(decoded.schemaVersion == 1)
        #expect(decoded.diagnostics.isEmpty)
        #expect(decoded.omittedDiagnosticCount == 0)
    }

    @Test func rawDumpDiagnosticsSortsDeduplicatesAndCapsRecords() {
        let diagnostics = (0...PrivateHeaderKitRawDumpDiagnosticsReport.maximumDiagnosticCount)
            .reversed()
            .map {
                PrivateHeaderKitRawDumpDiagnostic(
                    owner: "owner-\(String(format: "%03d", $0))",
                    degradation: "degraded"
                )
            }
        let report = PrivateHeaderKitRawDumpDiagnosticsReport(
            diagnostics: diagnostics + [diagnostics[0]],
            omittedDiagnosticCount: 2
        )

        #expect(
            report.diagnostics.count
                == PrivateHeaderKitRawDumpDiagnosticsReport.maximumDiagnosticCount
        )
        #expect(report.diagnostics.first?.owner == "owner-000")
        #expect(report.diagnostics.last?.owner == "owner-255")
        #expect(report.omittedDiagnosticCount == 3)
    }

    @Test func rawDumpDiagnosticsVisiblyEscapesControlAndFormatScalars() throws {
        let diagnostic = PrivateHeaderKitRawDumpDiagnostic(
            owner: "line\nowner\u{061c}",
            degradation: "tab\tvalue"
        )

        #expect(diagnostic.owner == #"line\nowner\u{061c}"#)
        #expect(diagnostic.degradation == #"tab\tvalue"#)
        let decoded = try JSONDecoder().decode(
            PrivateHeaderKitRawDumpDiagnosticsReport.self,
            from: JSONEncoder().encode(
                PrivateHeaderKitRawDumpDiagnosticsReport(diagnostics: [diagnostic])
            )
        )
        #expect(decoded.diagnostics == [diagnostic])
    }

    @Test func escapeHeavyMaximumReportFitsEncodedContract() throws {
        let field = String(repeating: #"\"#, count: 2_048)
        let diagnostics = (0..<PrivateHeaderKitRawDumpDiagnosticsReport.maximumDiagnosticCount)
            .map { index in
                PrivateHeaderKitRawDumpDiagnostic(
                    owner: field,
                    degradation: "\(index)-\(field)"
                )
            }
        let data = try JSONEncoder().encode(
            PrivateHeaderKitRawDumpDiagnosticsReport(diagnostics: diagnostics)
        )

        #expect(data.count <= PrivateHeaderKitRawDumpDiagnosticsReport.maximumEncodedByteCount)
    }

    @Test func rawDumpDiagnosticsRejectsWrongVersionMalformedAndNoncanonicalPayloads() {
        let payloads = [
            #"{"schemaVersion":2,"diagnostics":[],"omittedDiagnosticCount":0}"#,
            "not-json",
            #"{"schemaVersion":1,"diagnostics":[{"owner":"b","degradation":"x"},{"owner":"a","degradation":"x"}],"omittedDiagnosticCount":0}"#,
            #"{"schemaVersion":1,"diagnostics":[{"owner":"line\nowner","degradation":"x"}],"omittedDiagnosticCount":0}"#,
            #"{"schemaVersion":1,"diagnostics":[],"omittedDiagnosticCount":-1}"#,
        ]

        for payload in payloads {
            #expect(throws: (any Error).self) {
                _ = try JSONDecoder().decode(
                    PrivateHeaderKitRawDumpDiagnosticsReport.self,
                    from: Data(payload.utf8)
                )
            }
        }
    }

    @Test func rawDumpDiagnosticsDecoderRejectsExcessiveRecordCount() throws {
        let records = (0...PrivateHeaderKitRawDumpDiagnosticsReport.maximumDiagnosticCount)
            .map { index in
                "{\"owner\":\"owner-\(String(format: "%03d", index))\",\"degradation\":\"x\"}"
            }
            .joined(separator: ",")
        let data = Data(
            """
            {"schemaVersion":1,"diagnostics":[\(records)],"omittedDiagnosticCount":0}
            """.utf8
        )

        #expect(throws: PrivateHeaderKitRawDumpDiagnosticsReport.ValidationError.self) {
            _ = try JSONDecoder().decode(
                PrivateHeaderKitRawDumpDiagnosticsReport.self,
                from: data
            )
        }
    }

    @Test func rawDumpDiagnosticsDecoderRejectsNegativeOmittedCount() {
        let data = Data(
            #"{"schemaVersion":1,"diagnostics":[],"omittedDiagnosticCount":-1}"#.utf8
        )

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                PrivateHeaderKitRawDumpDiagnosticsReport.self,
                from: data
            )
        }
    }

    @Test func rawDumpDiagnosticsOmittedCountSaturates() {
        let report = PrivateHeaderKitRawDumpDiagnosticsReport(
            diagnostics: (0...PrivateHeaderKitRawDumpDiagnosticsReport.maximumDiagnosticCount).map { index in
                PrivateHeaderKitRawDumpDiagnostic(owner: "\(index)", degradation: "x")
            },
            omittedDiagnosticCount: UInt.max
        )

        #expect(report.omittedDiagnosticCount == UInt.max)
    }

    @Test func resolvedGraphPinsObjectiveCReaderForkExactly() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(
            contentsOf: packageRoot.appendingPathComponent("Package.resolved")
        )
        let document = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let pins = try #require(document["pins"] as? [[String: Any]])
        let pin = try #require(pins.first { $0["identity"] as? String == "machoobjcsection" })
        let state = try #require(pin["state"] as? [String: Any])

        #expect(pin["location"] as? String == "https://github.com/lynnswap/MachOObjCSection.git")
        #expect(state["revision"] as? String == "e8fdf4edc8f91aa46ef50f85932c1cb7690885af")
        #expect(state["version"] == nil)

        let swiftSectionPin = try #require(
            pins.first { $0["identity"] as? String == "machoswiftsection" }
        )
        let swiftSectionState = try #require(
            swiftSectionPin["state"] as? [String: Any]
        )
        #expect(
            swiftSectionPin["location"] as? String
                == "https://github.com/lynnswap/MachOSwiftSection.git"
        )
        #expect(
            swiftSectionState["revision"] as? String
                == "11a75142e0a0965363cff9e897719838dc975319"
        )
        #expect(swiftSectionState["version"] == nil)
    }

    @Test func inventoryNormalizesImagePathMembershipAndRoundTrips() throws {
        let cacheUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let inventory = try PrivateHeaderKitSharedCacheInventory(
            cacheUUID: cacheUUID,
            imagePaths: [
                "/usr/lib/libz.dylib",
                "/usr/lib/libobjc.A.dylib",
                "/usr/lib/libz.dylib",
            ]
        )

        #expect(inventory.schemaVersion == 1)
        #expect(inventory.imagePaths == [
            "/usr/lib/libobjc.A.dylib",
            "/usr/lib/libz.dylib",
        ])

        let decoded = try JSONDecoder().decode(
            PrivateHeaderKitSharedCacheInventory.self,
            from: JSONEncoder().encode(inventory)
        )
        #expect(decoded == inventory)
    }

    @Test func inventoryRejectsUnsupportedSchemaDuringDecode() {
        let data = Data(
            """
            {"schemaVersion":2,"cacheUUID":"11111111-2222-3333-4444-555555555555","imagePaths":[]}
            """.utf8
        )

        #expect(throws: PrivateHeaderKitSharedCacheInventory.ValidationError.self) {
            _ = try JSONDecoder().decode(PrivateHeaderKitSharedCacheInventory.self, from: data)
        }
    }

    @Test(arguments: [
        "usr/lib/libobjc.A.dylib",
        "/",
        "/usr//lib/libobjc.A.dylib",
        "/usr/lib/../libobjc.A.dylib",
        "/usr/lib/./libobjc.A.dylib",
    ])
    func inventoryRejectsNonLogicalPaths(_ path: String) {
        #expect(throws: PrivateHeaderKitSharedCacheInventory.ValidationError.self) {
            _ = try PrivateHeaderKitSharedCacheInventory(cacheUUID: UUID(), imagePaths: [path])
        }
    }

    @Test func inventoryRejectsMalformedPayload() {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                PrivateHeaderKitSharedCacheInventory.self,
                from: Data("not-json".utf8)
            )
        }
    }
}
