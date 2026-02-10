import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public final class OutputLock {
    public let lockPath: URL

    private var fd: Int32?

    public init(outDir: URL) throws {
        self.lockPath = outDir.appendingPathComponent(".dump_headers.lock")
        let path = lockPath.path

        let opened = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        if opened < 0 {
            throw ToolingError.message("failed to open lock file: \(path)")
        }
        self.fd = opened

        if flock(opened, LOCK_EX | LOCK_NB) != 0 {
            close(opened)
            self.fd = nil
            throw ToolingError.message("output directory is locked: \(outDir.path)")
        }

        _ = ftruncate(opened, 0)
        let started = ISO8601DateFormatter().string(from: Date())
        let text = "pid=\(getpid())\nstarted=\(started)\n"
        _ = text.withCString { ptr in
            write(opened, ptr, strlen(ptr))
        }
        _ = fsync(opened)
    }

    public func unlock(removeFile: Bool = true) {
        guard let fd else { return }
        self.fd = nil
        _ = flock(fd, LOCK_UN)
        close(fd)
        if removeFile {
            try? FileManager.default.removeItem(at: lockPath)
        }
    }

    deinit {
        unlock(removeFile: false)
    }
}

