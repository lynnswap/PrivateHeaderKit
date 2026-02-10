// Shared process tracking for responsive SIGINT/SIGTERM forwarding.
//
// Keep this async-signal-safe: store-only + kill(2), no allocations/IO.
// Best-effort: tracks only the currently-running subprocess started via ProcessRunner.

public nonisolated(unsafe) var gActiveToolingSubprocessPid: Int32 = 0

