import Foundation

// Convienence API for people interfacing with AsyncStream. Not sure why this isn't in Foundation by default...
extension AsyncStream {
  public var first: Element? {
    get async {
      await first(where: { _ in true })
    }
  }
}
