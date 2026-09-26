import Foundation
import Testing

@testable import PrivateHeaderKitHelperProtocol

@Suite
struct PrivateHeaderKitHelperProtocolTests {
    @Test func rawDumpProcessHandshakeRoundTripsItsExactBoundedSchema() throws {
        let invocationID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let executableUUID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let handshake = try PrivateHeaderKitRawDumpProcessHandshake(
            invocationID: invocationID,
            processIdentifier: 4_242,
            helperStartedAtUnixMicroseconds: 1_700_000_000_123_456,
            executableName: "privateheaderkit-sim-helper",
            executableMachOUUID: executableUUID
        )

        let data = try handshake.encoded()
        let decoded = try PrivateHeaderKitRawDumpProcessHandshake.decode(
            data,
            expectedInvocationID: invocationID
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(decoded == handshake)
        #expect(data.count <= PrivateHeaderKitRawDumpProcessHandshake.maximumEncodedByteCount)
        #expect(
            Set(object.keys) == [
                "schemaVersion",
                "invocationID",
                "processIdentifier",
                "helperStartedAtUnixMicroseconds",
                "executableName",
                "executableMachOUUID",
            ]
        )
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["processIdentifier"] as? Int == 4_242)
        #expect(object["executableName"] as? String == "privateheaderkit-sim-helper")
        let wire = String(decoding: data, as: UTF8.self)
        #expect(!wire.contains("/Users/"))
        #expect(!wire.contains("SIMCTL_CHILD"))
        #expect(!wire.contains("RuntimeRoot"))
    }

    @Test func rawDumpProcessHandshakeRejectsMismatchedInvocationAndOversizedPayload() throws {
        let invocationID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let unexpectedID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let handshake = try PrivateHeaderKitRawDumpProcessHandshake(
            invocationID: invocationID,
            processIdentifier: 4_242,
            helperStartedAtUnixMicroseconds: 1_700_000_000_123_456,
            executableName: "privateheaderkit-sim-helper",
            executableMachOUUID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        )

        #expect(
            throws: PrivateHeaderKitRawDumpProcessHandshake.ValidationError.invocationIDMismatch(
                expected: unexpectedID,
                actual: invocationID
            )
        ) {
            _ = try PrivateHeaderKitRawDumpProcessHandshake.decode(
                handshake.encoded(),
                expectedInvocationID: unexpectedID
            )
        }
        #expect(
            throws: PrivateHeaderKitRawDumpProcessHandshake.ValidationError.encodedPayloadTooLarge(
                actual: PrivateHeaderKitRawDumpProcessHandshake.maximumEncodedByteCount + 1,
                maximum: PrivateHeaderKitRawDumpProcessHandshake.maximumEncodedByteCount
            )
        ) {
            _ = try PrivateHeaderKitRawDumpProcessHandshake.decode(
                Data(
                    repeating: 0,
                    count: PrivateHeaderKitRawDumpProcessHandshake.maximumEncodedByteCount + 1
                ),
                expectedInvocationID: invocationID
            )
        }
    }

    @Test func rawDumpProcessHandshakeEnforcesExecutableNameBounds() throws {
        let invocationID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let executableUUID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let maximum = try PrivateHeaderKitRawDumpProcessHandshake(
            invocationID: invocationID,
            processIdentifier: 4_242,
            helperStartedAtUnixMicroseconds: 1_700_000_000_123_456,
            executableName: String(
                repeating: "\\",
                count: PrivateHeaderKitRawDumpProcessHandshake.maximumExecutableNameUTF8Count
            ),
            executableMachOUUID: executableUUID
        )

        #expect(
            try maximum.encoded().count
                <= PrivateHeaderKitRawDumpProcessHandshake.maximumEncodedByteCount
        )
        #expect(throws: PrivateHeaderKitRawDumpProcessHandshake.ValidationError.self) {
            _ = try PrivateHeaderKitRawDumpProcessHandshake(
                invocationID: invocationID,
                processIdentifier: 4_242,
                helperStartedAtUnixMicroseconds: 1_700_000_000_123_456,
                executableName: String(
                    repeating: "e",
                    count: PrivateHeaderKitRawDumpProcessHandshake.maximumExecutableNameUTF8Count + 1
                ),
                executableMachOUUID: executableUUID
            )
        }
    }

    @Test func rawDumpProcessHandshakeStrictlyRejectsInvalidFields() {
        let expectedID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let validFields = #""schemaVersion":1,"invocationID":"11111111-2222-3333-4444-555555555555","processIdentifier":4242,"helperStartedAtUnixMicroseconds":1700000000123456,"executableName":"privateheaderkit-sim-helper","executableMachOUUID":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee""#
        let payloads = [
            "{\(validFields),\"path\":\"/private/var/tmp/helper\"}",
            "{\(validFields.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2"))}",
            "{\(validFields.replacingOccurrences(of: "11111111-2222-3333-4444-555555555555", with: "00000000-0000-0000-0000-000000000000"))}",
            "{\(validFields.replacingOccurrences(of: "\"processIdentifier\":4242", with: "\"processIdentifier\":0"))}",
            "{\(validFields.replacingOccurrences(of: "\"helperStartedAtUnixMicroseconds\":1700000000123456", with: "\"helperStartedAtUnixMicroseconds\":0"))}",
            "{\(validFields.replacingOccurrences(of: "privateheaderkit-sim-helper", with: "/private/helper"))}",
            "{\(validFields.replacingOccurrences(of: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", with: "00000000-0000-0000-0000-000000000000"))}",
        ]

        for payload in payloads {
            #expect(throws: (any Error).self) {
                _ = try PrivateHeaderKitRawDumpProcessHandshake.decode(
                    Data(payload.utf8),
                    expectedInvocationID: expectedID
                )
            }
        }
    }

    @Test func rawDumpDiagnosticsZeroReportRoundTrips() throws {
        let report = PrivateHeaderKitRawDumpDiagnosticsReport(
            producerVersion: "v1.2.3",
            diagnostics: []
        )
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(
            PrivateHeaderKitRawDumpDiagnosticsReport.self,
            from: data
        )

        #expect(decoded.schemaVersion == 2)
        #expect(decoded.producerVersion == "v1.2.3")
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
            #"{"schemaVersion":3,"producerVersion":"v1.2.3","diagnostics":[],"omittedDiagnosticCount":0}"#,
            "not-json",
            #"{"schemaVersion":2,"producerVersion":"v1.2.3","diagnostics":[{"owner":"b","degradation":"x"},{"owner":"a","degradation":"x"}],"omittedDiagnosticCount":0}"#,
            #"{"schemaVersion":2,"producerVersion":"v1.2.3","diagnostics":[{"owner":"line\nowner","degradation":"x"}],"omittedDiagnosticCount":0}"#,
            #"{"schemaVersion":2,"producerVersion":"v1.2.3","diagnostics":[],"omittedDiagnosticCount":-1}"#,
            #"{"schemaVersion":2,"producerVersion":"","diagnostics":[],"omittedDiagnosticCount":0}"#,
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
            {"schemaVersion":2,"producerVersion":"v1.2.3","diagnostics":[\(records)],"omittedDiagnosticCount":0}
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
            #"{"schemaVersion":2,"producerVersion":"v1.2.3","diagnostics":[],"omittedDiagnosticCount":-1}"#.utf8
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

    @Test func resolvedGraphPinsReaderForksExactly() throws {
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
        #expect(state["revision"] as? String == "5576f1e1f53ed88faf4e71c781246f7ec1cd1b24")
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
                == "04ff26795fca8efc88fce2bb3d09fa0a947e56bf"
        )
        #expect(swiftSectionState["version"] == nil)

        let machOKitPin = try #require(
            pins.first { $0["identity"] as? String == "machokit" }
        )
        let machOKitState = try #require(
            machOKitPin["state"] as? [String: Any]
        )
        #expect(
            machOKitPin["location"] as? String
                == "https://github.com/MxIris-Reverse-Engineering/MachOKit.git"
        )
        #expect(
            machOKitState["revision"] as? String
                == "8d451ca2e9d108f0a2024758b33b25e8faa2adbb"
        )
        #expect(machOKitState["version"] == nil)

        let mirrorData = try Data(
            contentsOf: packageRoot
                .appendingPathComponent(".swiftpm/configuration/mirrors.json")
        )
        let mirrorDocument = try #require(
            JSONSerialization.jsonObject(with: mirrorData) as? [String: Any]
        )
        let mirrors = try #require(
            mirrorDocument["object"] as? [[String: String]]
        )
        let expectedMirror = "https://github.com/lynnswap/MachOKit.git"
        #expect(Set(mirrors.compactMap { $0["mirror"] }) == [expectedMirror])
        #expect(
            Set(mirrors.compactMap { $0["original"] }) == [
                "https://github.com/MxIris-Reverse-Engineering/MachOKit",
                "https://github.com/MxIris-Reverse-Engineering/MachOKit.git",
            ]
        )
    }

    @Test func inventoryNormalizesImagePathMembershipAndRoundTrips() throws {
        let cacheUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let inventory = try PrivateHeaderKitSharedCacheInventory(
            producerVersion: "v1.2.3",
            cacheUUID: cacheUUID,
            imagePaths: [
                "/usr/lib/libz.dylib",
                "/usr/lib/libobjc.A.dylib",
                "/usr/lib/libz.dylib",
            ]
        )

        #expect(inventory.schemaVersion == 2)
        #expect(inventory.producerVersion == "v1.2.3")
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
            {"schemaVersion":3,"producerVersion":"v1.2.3","cacheUUID":"11111111-2222-3333-4444-555555555555","imagePaths":[]}
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
