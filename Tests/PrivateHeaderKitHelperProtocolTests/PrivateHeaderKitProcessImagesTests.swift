import Foundation
import PrivateHeaderKitHelperProtocol
import Testing

@Suite struct PrivateHeaderKitProcessImagesTests {
    private var image: PrivateHeaderKitProcessImage {
        .init(loadAddress: 0x10000, path: "/synthetic/Sample.app/Sample", uuid: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
              cpuType: 0x0100_000c, cpuSubtype: 0, fileType: 2)
    }

    @Test func inventoryRoundTripRetainsIndividualInspectionFailures() throws {
        let report = try PrivateHeaderKitProcessImageInventory(
            processIdentifier: 1234, images: [image],
            failures: [.init(loadAddress: 0x30000, path: nil, error: "unreadable image header")]
        )
        let decoded = try JSONDecoder().decode(PrivateHeaderKitProcessImageInventory.self,
                                                from: JSONEncoder().encode(report))
        #expect(decoded == report)
        #expect(decoded.failures.count == 1)
    }

    @Test func recoveryRoundTripRetainsActiveArchitectureAndZeroByteSuccess() throws {
        let report = try PrivateHeaderKitRecoveredProcessImage(
            processIdentifier: 1234, image: image, outputPath: "/synthetic/output.macho", encryptedBytesRecovered: 0
        )
        let decoded = try JSONDecoder().decode(PrivateHeaderKitRecoveredProcessImage.self,
                                                from: JSONEncoder().encode(report))
        #expect(decoded == report)
        #expect(decoded.encryptedBytesRecovered == 0)
    }

    @Test func incompatibleInventoryAndRecoverySchemasAreRejected() throws {
        let inventory = try PrivateHeaderKitProcessImageInventory(processIdentifier: 1234, images: [image], failures: [])
        let recovered = try PrivateHeaderKitRecoveredProcessImage(
            processIdentifier: 1234, image: image, outputPath: "/synthetic/output.macho", encryptedBytesRecovered: 64
        )
        func incompatible(_ report: some Encodable) throws -> Data {
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
            object["schemaVersion"] = 2
            return try JSONSerialization.data(withJSONObject: object)
        }
        #expect(throws: PrivateHeaderKitProcessImageReportError.unsupportedSchemaVersion(2)) {
            try JSONDecoder().decode(PrivateHeaderKitProcessImageInventory.self, from: incompatible(inventory))
        }
        #expect(throws: PrivateHeaderKitProcessImageReportError.unsupportedSchemaVersion(2)) {
            try JSONDecoder().decode(PrivateHeaderKitRecoveredProcessImage.self, from: incompatible(recovered))
        }
    }
}
