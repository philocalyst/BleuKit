import Dispatch
import Foundation

internal final class AsyncSubscriptionQueue<Value> {
  private var items: [AsyncSubscription<Value>] = []
  private let lock = NSLock()

  internal var isEmpty: Bool {
    lock.lock()
    defer { lock.unlock() }
    return items.isEmpty
  }

  @discardableResult
  internal func queue(
    block: @escaping (Value, () -> Void) -> Void,
    completion: (() -> Void)? = nil
  ) -> AsyncSubscription<Value> {
    let item = AsyncSubscription(
      parent: self, block: block,
      completion: completion)
    lock.lock()
    defer { lock.unlock() }
    items.append(item)
    return item
  }

  internal func receive(_ value: Value) {
    // Take a snapshot of the values under the lock.
    lock.lock()
    let snapshot = items
    lock.unlock()

    // Invoke callbacks outside of the lock
    for item in snapshot.reversed() {
      item.block(value, item.cancel)
    }
  }

  internal func remove(_ item: AsyncSubscription<Value>) {
    lock.lock()
    defer { lock.unlock() }
    items.removeAll { $0 == item }
  }
}
