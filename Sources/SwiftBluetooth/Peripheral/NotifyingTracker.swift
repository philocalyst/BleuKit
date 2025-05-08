import Foundation

/// Tracks notify-state subscriptions both from external callers
/// and internal stream subscribers.
internal final class NotifyingTracker<Key> where Key: Hashable {
  private var external: [Key: Bool] = [:]
  private var `internal`: [Key: Int] = [:]
  let lock = NSLock()

  /// Sets the external desired notify value for a characteristic.
  ///
  /// - Parameters:
  ///   - value: `true` to start notifying, `false` to stop.
  ///   - key: The characteristic UUID key.
  /// - Returns: The same `value`.
  func setExternal(_ value: Bool, forKey key: Key) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    external[key] = value
    return value
  }

  /// Increments the count of internal subscribers for a key.
  ///
  /// - Parameter key: The characteristic UUID.
  func addInternal(forKey key: Key) {
    lock.lock()
    defer { lock.unlock() }
    `internal`[key] = (`internal`[key] ?? 0) + 1
  }

  /// Decrements the internal subscriber count, and determines
  /// whether notifications should remain enabled.
  ///
  /// - Parameter key: The characteristic UUID.
  /// - Returns: `true` if remaining internal or external subscribers
  ///            require notifications to stay on.
  func removeInternal(forKey key: Key) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let count = max((`internal`[key] ?? 1) - 1, 0)
    `internal`[key] = count
    return count > 0 || (external[key] ?? false)
  }
}
