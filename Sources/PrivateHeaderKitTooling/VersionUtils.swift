import Foundation

public enum VersionUtils {
    public static func versionKey(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }
}

