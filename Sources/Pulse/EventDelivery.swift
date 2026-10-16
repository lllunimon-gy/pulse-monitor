import Foundation

public struct DeliveryStatistics: Codable {
    public let retainedEvents: Int
    public let droppedEvents: Int
    public let coalescedUpdates: Int
    public let invalidatedEvents: Int
}

/// Stores event records, not unbounded asynchronous blocks. Recovery updates an admitted ID.
final class EventDelivery {
    private struct Slot {
        var latest: HangEvent?
    }
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let capacity: Int
    private let handler: (HangEvent) -> Void
    private var slots: [UUID: Slot] = [:]
    private var order: [UUID] = []
    private var rejectedOngoing: UUID?
    private var scheduled = false
    private var dropped = 0
    private var coalesced = 0
    private var invalidated = 0

    init(capacity: Int, queue: DispatchQueue = DispatchQueue(label: "dev.gy.pulse.events", qos: .utility),
         handler: @escaping (HangEvent) -> Void) {
        precondition((1...4096).contains(capacity))
        self.capacity = capacity; self.queue = queue; self.handler = handler
    }

    func submit(_ events: [HangEvent]) {
        guard !events.isEmpty else { return }
        lock.lock()
        for event in events {
            if event.id == rejectedOngoing {
                if event.phase != .detected { rejectedOngoing = nil }
                continue
            }
            if let slot = slots[event.id] {
                if slot.latest != nil { coalesced += 1 }
                slots[event.id] = Slot(latest: event)
            } else if slots.count < capacity {
                slots[event.id] = Slot(latest: event)
                order.append(event.id)
            } else {
                dropped += 1
                if event.phase == .detected { rejectedOngoing = event.id }
            }
        }
        let needsDrain = !scheduled && slots.values.contains { $0.latest != nil }
        if needsDrain { scheduled = true }
        lock.unlock()
        if needsDrain { queue.async { [weak self] in self?.drain() } }
    }

    func invalidate() {
        lock.lock()
        invalidated += slots.count
        slots.removeAll(); order.removeAll(); rejectedOngoing = nil
        lock.unlock()
    }

    var statistics: DeliveryStatistics {
        lock.lock(); defer { lock.unlock() }
        return DeliveryStatistics(retainedEvents: slots.count, droppedEvents: dropped,
                                  coalescedUpdates: coalesced, invalidatedEvents: invalidated)
    }

    private func drain() {
        while true {
            lock.lock()
            guard let id = order.first(where: { slots[$0]?.latest != nil }),
                  let event = slots[id]?.latest else {
                scheduled = false
                lock.unlock()
                return
            }
            if event.phase == .detected {
                slots[id] = Slot(latest: nil) // Reserve a slot for this event's terminal update.
            } else {
                slots.removeValue(forKey: id)
                order.removeAll { $0 == id }
            }
            lock.unlock()
            // Dequeued callbacks are in-flight; stop does not wait for user code.
            handler(event)
        }
    }
}
