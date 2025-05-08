import Foundation

/// Represents a single subscription in an async subscription queue.
///
/// Each `AsyncSubscription` has a unique identifier and holds:
/// - a callback `block` to invoke when a new value arrives,
/// - an optional `completion` to run when the subscription is cancelled,
/// - and a weak reference to its parent queue so it can remove itself.
///
/// Conforms to `Identifiable`, `Equatable` (by `id`), and `CancellableTask`.
internal struct AsyncSubscription<Value>: Identifiable, Equatable, CancellableTask {
  /// Unique identifier of this subscription.
  public let id = UUID()

  /// The queue that owns this subscription.
  weak var parent: AsyncSubscriptionQueue<Value>?

  /// The callback invoked when a new `Value` is received.
  /// - Parameters:
  ///   - value: The emitted value.
  ///   - done: Call this closure to remove this subscription from its queue.
  let block: (Value, () -> Void) -> Void

  /// Optional closure that is called when this subscription is cancelled.
  let completion: (() -> Void)?

  /// Cancels this subscription:
  /// - removes it from its parent queue,
  /// - invokes the `completion` closure if provided.
  public func cancel() {
    parent?.remove(self)
    completion?()
  }

  // MARK: - Equatable

  /// Two subscriptions are equal if their `id`s match.
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id
  }
}
