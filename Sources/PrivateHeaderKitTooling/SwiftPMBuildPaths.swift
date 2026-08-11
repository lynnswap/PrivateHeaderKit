import Foundation

package enum SwiftPMBuildPaths {
    package static func simulatorScratchURL(repoRoot: URL, triple: String) -> URL {
        repoRoot
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("privateheaderkit-simulator", isDirectory: true)
            .appendingPathComponent(triple, isDirectory: true)
    }
}
