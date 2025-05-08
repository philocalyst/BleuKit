import Foundation

/// Represents a cancellable asynchronous task or subscription.
///
/// Conforming types implement `cancel()` to stop any further work.
public protocol CancellableTask {
  /// Cancels this task or subscription.
  func cancel()
}
