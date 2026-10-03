import Foundation
import Testing
@testable import PrivateHeaderKitRawDumpCore
import PrivateHeaderKitExecutableResolution

struct LogicalImagePathTests {
  @Test func oneLogicalImagePathCannotOverwriteMultipleRecursiveTargets() {
    #expect(parseArguments(["-r", "--image-path", "/Applications/Sample.app/Executable", "/tmp/owned-recovery"]) == nil)
  }
  @Test func logicalIdentityDoesNotChangeThePhysicalFileInput() throws {
    let parsed = try #require(parseArguments([
      "-o", "/tmp/output", "-b", "-h", "--image-path", "/Applications/Sample.app/Executable",
      "/tmp/owned-recovery/Executable"
    ]))
    #expect(parsed.inputPath == "/tmp/owned-recovery/Executable")
    let placement = outputPlacement(
      for: .direct(URL(fileURLWithPath: parsed.inputPath)), outputRoot: parsed.options.outputDir,
      options: parsed.options, environment: [:]
    )
    #expect(placement.directory.path == "/tmp/output/Applications/Sample.app/Headers")
    #expect(!parsed.options.useRuntimeFallback)
    #expect(!parsed.options.useSharedCache)
    #expect(!parsed.options.recursive)
  }
}
