import Foundation

/// A thread-safe dictionary of `AsyncSubscriptionQueue<Value>`s keyed by `Key`.
///
/// You can register subscriptions under individual keys, and later
/// send values *only* to the queue for a specific key.
internal final class AsyncSubscriptionQueueMap<Key, Value> where Key: Hashable {
  private var items: [Key: AsyncSubscriptionQueue<Value>] = [:]
  private let lock = NSLock()

  /// Creates an empty map.
  internal init() {}

  /// Returns `true` if *all* queues in the map are empty.
  internal var isEmpty: Bool {
    lock.lock()
    defer { lock.unlock() }
    return items.values.allSatisfy { $0.isEmpty }
  }

  /// Enqueues a subscription under `key`.
  /// - Parameters:
  ///   - key: The key of the queue.
  ///   - block: Called with the new value and a `done` callback.
  ///   - completion: Called when the subscription is cancelled.
  /// - Returns: The created `AsyncSubscription<Value>`.
  @discardableResult
  internal func queue(
    key: Key,
    block: @escaping (Value, () -> Void) -> Void,
    completion: (() -> Void)? = nil
  ) -> AsyncSubscription<Value> {
    // grab-or-create queue
    lock.lock()
    var queue = items[key]
    if queue == nil {
      queue = AsyncSubscriptionQueue<Value>()
      items[key] = queue!
    }
    lock.unlock()

    return queue!.queue(block: block, completion: completion)
  }

  /// Sends `value` into the queue for `key`.
  /// - Parameters:
  ///   - key: The key whose queue should receive `value`.
  ///   - value: The value to dispatch.
  internal func receive(key: Key, withValue value: Value) {
    lock.lock()
    let queue = items[key]
    lock.unlock()
    queue?.receive(value)
  }
}
