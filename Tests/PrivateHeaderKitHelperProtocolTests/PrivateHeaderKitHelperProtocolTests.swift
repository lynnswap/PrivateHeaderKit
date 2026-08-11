import Foundation
import Testing

@testable import PrivateHeaderKitHelperProtocol

@Suite
struct PrivateHeaderKitHelperProtocolTests {
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
