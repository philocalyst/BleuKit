import CoreBluetooth
import Foundation

/// Marks `CBUUID` as conforming to `Sendable` for Swift concurrency.
///
/// CoreBluetooth’s `CBUUID` is safe to send across threads, so we
/// add an unchecked `Sendable` conformance.
@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
extension CBUUID: @unchecked @retroactive Sendable {}
