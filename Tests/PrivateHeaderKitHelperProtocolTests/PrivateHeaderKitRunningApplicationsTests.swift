import Foundation
import PrivateHeaderKitHelperProtocol
import Testing

@Suite struct PrivateHeaderKitRunningApplicationsTests {
    @Test func selectedApplicationReportRoundTripsOnlyItsMetadata() throws {
        let image = PrivateHeaderKitProcessImage(
            loadAddress: 0x10000, path: "/synthetic/Sample.app/Sample",
            uuid: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, cpuType: 0x0100_000c, cpuSubtype: 0, fileType: 2
        )
        let report = try PrivateHeaderKitRunningApplicationReport(application: .init(
            processIdentifier: 100, bundleIdentifier: "com.example.Sample", version: "1.2.3", build: "45",
            executableName: "Sample", mainImage: image
        ), systemVersion: .init(version: "26.0", build: "23A100", metadataIsSeed: false))
        let data = try JSONEncoder().encode(report)
        #expect(try JSONDecoder().decode(PrivateHeaderKitRunningApplicationReport.self, from: data) == report)
    }

    @Test func missingOptionalVersionMetadataIsRetainedAsAbsent() throws {
        let image = PrivateHeaderKitProcessImage(
            loadAddress: 0x10000, path: "/synthetic/Sample.app/Sample",
            uuid: UUID(), cpuType: 0x0100_000c, cpuSubtype: 0, fileType: 2
        )
        let report = try PrivateHeaderKitRunningApplicationReport(application: .init(
            processIdentifier: 100, bundleIdentifier: "com.example.Sample", version: nil, build: nil,
            executableName: "Sample", mainImage: image
        ))
        let decoded = try JSONDecoder().decode(PrivateHeaderKitRunningApplicationReport.self,
                                                from: JSONEncoder().encode(report))
        #expect(decoded.application.version == nil)
        #expect(decoded.application.build == nil)
    }
}
