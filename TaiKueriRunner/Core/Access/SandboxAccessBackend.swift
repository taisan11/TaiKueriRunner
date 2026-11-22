import Foundation

// Dependency injection for host tests; the app always uses the native backend.
struct SandboxAccessBackend: Sendable {
    let acquire: @Sendable (String) throws -> Int64
    let release: @Sendable (Int64) -> Void
}
