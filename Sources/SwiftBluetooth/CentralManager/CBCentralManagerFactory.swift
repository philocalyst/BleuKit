import CoreBluetooth
import Foundation

/// Factory abstraction for creating `CBCentralManager` instances.
///
/// This allows you to swap in a mock central manager (via `SwiftBluetoothMock`)
/// without changing your business‐logic code.
enum CBCentralManagerFactory {

  /// Creates a new `CBCentralManager`.  When using the mock target,
  /// `forceMock` will return a `CBMCentralManager` instead.
  ///
  /// - Parameters:
  ///   - delegate: The `CBCentralManagerDelegate` to receive events.
  ///   - queue: Dispatch queue for delegate callbacks.
  ///   - options: Initialization dictionary (same as `CBCentralManager`).
  ///   - forceMock: If `true`, returns the mock manager in a test build.
  /// - Returns: A new `CBCentralManager` (real or mock).
  static func instance(
    delegate: CBCentralManagerDelegate? = nil,
    queue: DispatchQueue? = nil,
    options: [String: Any]? = nil,
    forceMock: Bool
  ) -> CBCentralManager {
    return CBCentralManager(delegate: delegate, queue: queue, options: options)
  }
}
