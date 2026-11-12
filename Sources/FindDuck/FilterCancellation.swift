import Foundation

struct FilterCancellation<Key: Hashable> {
    private var conditions: [Key] = []

    mutating func record(_ key: Key, active: Bool) {
        conditions.removeAll { $0 == key }
        if active { conditions.append(key) }
    }

    mutating func pop() -> Key? { conditions.popLast() }
}
