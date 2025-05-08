import Foundation

internal final class AsyncSubscriptionQueueMap<Key, Value> where Key: Hashable {
  private var items: [Key: AsyncSubscriptionQueue<Value>] = [:]
  private let lock = NSLock()

  internal init() {}

  internal var isEmpty: Bool {
    lock.lock()
    defer { lock.unlock() }
    return items.values.allSatisfy { $0.isEmpty }
  }

  @discardableResult
  internal func queue(
    key: Key,
    block: @escaping (Value, () -> Void) -> Void,
    completion: (() -> Void)? = nil
  ) -> AsyncSubscription<Value> {
    // Grab-or-create the queue under lock
    lock.lock()
    var queue = items[key]
    if queue == nil {
      queue = AsyncSubscriptionQueue<Value>()
      items[key] = queue!
    }
    lock.unlock()

    // Enqueue outside the lock
    return queue!.queue(block: block, completion: completion)
  }

  internal func receive(key: Key, withValue value: Value) {
    // Snapshot the queue reference under lock
    lock.lock()
    let queue = items[key]
    lock.unlock()

    // Deliver outside the lock
    queue?.receive(value)
  }
}
