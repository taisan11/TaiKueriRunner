// Bounded flag fallback adapted from WQFiles WQAccess.m (GPL-3.0-or-later).
import Foundation

enum SandboxGrantPolicy {
    struct Result {
        let handle: Int64
        let alternateFlags: Bool
    }

    static func prefersAlternateFlags(majorVersion: Int) -> Bool { majorVersion == 26 }

    static func acquire(preferAlternate: Bool, query: (Bool) -> Int64,
                        sandboxAllowsOpen: () -> Bool, release: (Int64) -> Void) throws -> Result {
        var lastCode: Int64 = -8
        for flags in [preferAlternate, !preferAlternate] {
            let handle = query(flags)
            if handle >= 0 {
                if sandboxAllowsOpen() { return Result(handle: handle, alternateFlags: flags) }
                release(handle) // Zero is also a valid handle.
                lastCode = -8
            } else {
                lastCode = handle
                // Changing flags cannot fix signing or missing private APIs.
                if handle == -1 || handle == -2 { break }
            }
        }
        throw RunnerError(FileAccessManager.queryError(lastCode))
    }
}
