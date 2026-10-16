import Foundation

/// Caller supplies synchronization. Append is O(1); snapshots are chronological.
struct BoundedBuffer<Element> {
    let capacity: Int
    private var slots: [Element?]
    private var next = 0
    private(set) var count = 0
    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        slots = Array(repeating: nil, count: capacity)
    }
    mutating func append(_ element: Element) {
        slots[next] = element
        next = (next + 1) % capacity
        count = min(capacity, count + 1)
    }
    func snapshot() -> [Element] {
        let first = (next - count + capacity) % capacity
        return (0..<count).compactMap { slots[(first + $0) % capacity] }
    }
    mutating func removeAll() {
        slots = Array(repeating: nil, count: capacity)
        next = 0
        count = 0
    }
}
