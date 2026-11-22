import Foundation

/// A lightweight in-memory cache owned by a reading actor.
///
/// Unlike the previous time-based cache, an entry stays valid for the whole
/// app session. Application and App Group lists are only re-read when no
/// cached value exists or the user explicitly asks for a refresh. The token
/// rejects late, superseded reads so an older request cannot overwrite a newer
/// result.
struct SessionReadCache<Key: Equatable & Sendable, Value: Sendable>: Sendable {
    private var entry: (key: Key, value: Value)?
    private var generation = UUID()

    init() {}

    mutating func value(for key: Key) -> Value? {
        guard let entry, entry.key == key else { return nil }
        return entry.value
    }

    @discardableResult
    mutating func invalidate() -> UUID {
        entry = nil
        generation = UUID()
        return generation
    }

    mutating func store(_ value: Value, for key: Key, token: UUID) {
        guard generation == token else { return }
        entry = (key, value)
    }
}
