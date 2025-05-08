import Dispatch
import Foundation

/// A thread-safe queue of `AsyncSubscription<Value>`s.
///
/// You can enqueue callback blocks that will all be invoked when
/// `receive(_:)` is called.  Subscriptions may cancel themselves by
/// calling the provided `done` closure.
internal final class AsyncSubscriptionQueue<Value> {
  private var items: [AsyncSubscription<Value>] = []
  private let lock = NSLock()

  /// Returns `true` if there are no active subscriptions.
  internal var isEmpty: Bool {
    lock.lock()
    defer { lock.unlock() }
    return items.isEmpty
  }

  /// Enqueues a new subscription.
  /// - Parameters:
  ///   - block: Called whenever a new `Value` arrives.  The block receives
  ///            the new value and a `done` closure to cancel itself.
  ///   - completion: Called when the subscription is cancelled.
  /// - Returns: The created `AsyncSubscription<Value>`.
  @discardableResult
  internal func queue(
    block: @escaping (Value, () -> Void) -> Void,
    completion: (() -> Void)? = nil
  ) -> AsyncSubscription<Value> {
    let item = AsyncSubscription(parent: self, block: block, completion: completion)
    lock.lock()
    defer { lock.unlock() }
    items.append(item)
    return item
  }

  /// Emits a new value to *all* current subscriptions.
  /// Subscriptions are invoked in reverse insertion order.
  /// - Parameter value: The new value to dispatch.
  internal func receive(_ value: Value) {
    // snapshot under lock
    lock.lock()
    let snapshot = items
    lock.unlock()

    // invoke outside lock
    for item in snapshot.reversed() {
      item.block(value, item.cancel)
    }
  }

  /// Removes a subscription from this queue.
  /// - Parameter item: The subscription to remove.
  internal func remove(_ item: AsyncSubscription<Value>) {
    lock.lock()
    defer { lock.unlock() }
    items.removeAll { $0 == item }
  }
}
