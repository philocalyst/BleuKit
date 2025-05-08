import Foundation

/// Extensions to perform synchronization safely on DispatchQueues.
extension DispatchQueue {
  private static let idKey = DispatchSpecificKey<Int>()

  /// A unique identifier for this queue.
  var id: Int {
    let value = unsafeBitCast(self, to: Int.self)
    setSpecific(key: Self.idKey, value: value)
    return value
  }

  /// Indicates whether the current execution context is this queue.
  var isCurrent: Bool {
    id == DispatchQueue.getSpecific(key: Self.idKey)
  }

  /// Performs `block` synchronously on this queue, avoiding deadlocks
  /// if already on this queue.
  ///
  /// - Parameters:
  ///   - flags: Optional `DispatchWorkItemFlags`.
  ///   - block: The work to perform.
  /// - Returns: The value returned by `block`.
  /// - Throws: Any error thrown by `block`.
  func safeSync<T>(
    flags: DispatchWorkItemFlags? = nil,
    execute block: () throws -> T
  ) rethrows -> T {
    try isCurrent
      ? block()
      : sync(flags: flags ?? [], execute: block)
  }
}
