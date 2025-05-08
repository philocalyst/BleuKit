import CoreBluetooth
import Foundation

/// Internal event types emitted by `CentralManagerDelegateWrapper`
/// and consumed by `AsyncSubscriptionQueue<CentralManagerEvent>`.
internal enum CentralManagerEvent {
  /// The Bluetooth state changed.
  case stateUpdated(CBManagerState)
  /// A peripheral was discovered.
  case discovered(Peripheral, [String: Any], NSNumber)
  /// A peripheral connected.
  case connected(Peripheral)
  /// A peripheral disconnected (with optional error).
  case disconnected(Peripheral, Error?)
  /// A connection attempt failed.
  case failToConnect(Peripheral, Error?)
  /// System will restore state for scanning or connections.
  case restoreState([String: Any])
  /// Scanning was stopped.
  case stopScan
}
