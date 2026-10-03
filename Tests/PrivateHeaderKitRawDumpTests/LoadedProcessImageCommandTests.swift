import Foundation
import Testing
@testable import PrivateHeaderKitRawDumpCore

#if canImport(Darwin)
@Suite struct LoadedProcessImageCommandTests {
    @Test(arguments: [
        [], ["unknown"], ["__process-images"], ["__process-images", "--pid", "0"],
        ["__process-images", "--pid", "1", "--unknown", "value"],
        ["__process-images", "--pid", "1", "--pid", "2"],
        ["__recover-process-image", "--pid", "1", "--image-address", "1234", "--output", "/synthetic/output"],
        ["__recover-process-image", "--pid", "1", "--image-address", "1234", "--expected-uuid", "invalid", "--output", "/synthetic/output"],
    ]) func malformedRequestIsRejectedBeforeAcquiringATask(arguments: [String]) {
        #expect(throws: LoadedProcessImageCommand.CommandError.invalidArguments) {
            try LoadedProcessImageCommand.run(arguments: arguments)
        }
    }
}
#endif
