import Foundation

/// Convenience extension to get the first element of an AsyncStream.
extension AsyncStream {
  /// Asynchronously returns the first element emitted by this stream,
  /// or `nil` if the stream finishes without emitting.
  public var first: Element? {
    get async {
      await first(where: { _ in true })
    }
  }
}
