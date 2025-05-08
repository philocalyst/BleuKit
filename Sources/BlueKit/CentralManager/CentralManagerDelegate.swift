import CoreBluetooth
import Dispatch
import Foundation

/// Delegate protocol to receive high-level CentralManager events.
///
/// Implement this protocol to observe state changes, connection events,
/// discoveries, and other CoreBluetooth central-manager callbacks.
public protocol CentralManagerDelegate: AnyObject {
  /// Called whenever the Bluetooth state changes.
  ///
  /// - Parameter central: The `CentralManager` whose state changed.
  func centralManagerDidUpdateState(_ central: CentralManager)

  /// Called when a peripheral has successfully connected.
  ///
  /// - Parameters:
  ///   - central: The `CentralManager` instance.
  ///   - peripheral: The connected `Peripheral`.
  func centralManager(
    _ central: CentralManager,
    didConnect peripheral: Peripheral
  )

  /// Called when a peripheral disconnects.
  ///
  /// - Parameters:
  ///   - central: The `CentralManager` instance.
  ///   - peripheral: The `Peripheral` that disconnected.
  ///   - error: An error if the disconnection was unexpected, otherwise `nil`.
  func centralManager(
    _ central: CentralManager,
    didDisconnectPeripheral peripheral: Peripheral,
    error: Error?
  )

  /// Called when a connection attempt fails.
  ///
  /// - Parameters:
  ///   - central: The `CentralManager` instance.
  ///   - peripheral: The `Peripheral` that failed to connect.
  ///   - error: An error describing the failure, or `nil`.
  func centralManager(
    _ central: CentralManager,
    didFailToConnect peripheral: Peripheral,
    error: Error?
  )

  #if os(iOS)
    /// Called on iOS when a low-level connection event occurs.
    ///
    /// - Parameters:
    ///   - central: The `CentralManager` instance.
    ///   - event: The `CBConnectionEvent`.
    ///   - peripheral: The `Peripheral` related to the event.
    func centralManager(
      _ central: CentralManager,
      connectionEventDidOccur event: CBConnectionEvent,
      for peripheral: Peripheral
    )

    /// Called on iOS when ANCS authorization updates for a peripheral.
    ///
    /// - Parameters:
    ///   - central: The `CentralManager` instance.
    ///   - peripheral: The `Peripheral` whose ANCS authorization changed.
    func centralManager(
      _ central: CentralManager,
      didUpdateANCSAuthorizationFor peripheral: Peripheral
    )
  #endif

  /// Called when a peripheral is discovered during scanning.
  ///
  /// - Parameters:
  ///   - central: The `CentralManager` instance.
  ///   - peripheral: The discovered `Peripheral`.
  ///   - advertisementData: Dictionary of advertisement data.
  ///   - RSSI: The received signal strength indicator.
  func centralManager(
    _ central: CentralManager,
    didDiscover peripheral: Peripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  )

  /// Called when the central manager’s state will be restored by the system.
  ///
  /// - Parameters:
  ///   - central: The `CentralManager` instance.
  ///   - dict: The restoration dictionary provided by CoreBluetooth.
  func centralManager(_ central: CentralManager, willRestoreState dict: [String: Any])
}

// MARK: - Default Implementations

extension CentralManagerDelegate {
  public func centralManagerDidUpdateState(_ central: CentralManager) {}
  public func centralManager(
    _ central: CentralManager,
    didConnect peripheral: Peripheral
  ) {}
  public func centralManager(
    _ central: CentralManager,
    didDisconnectPeripheral peripheral: Peripheral,
    error: Error?
  ) {}
  public func centralManager(
    _ central: CentralManager,
    didFailToConnect peripheral: Peripheral,
    error: Error?
  ) {}
  #if os(iOS)
    func centralManager(
      _ central: CentralManager,
      connectionEventDidOccur event: CBConnectionEvent,
      for peripheral: Peripheral
    ) {}
    func centralManager(
      _ central: CentralManager,
      didUpdateANCSAuthorizationFor peripheral: Peripheral
    ) {}
  #endif
  public func centralManager(
    _ central: CentralManager,
    didDiscover peripheral: Peripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {}
  public func centralManager(_ central: CentralManager, willRestoreState dict: [String: Any]) {}
}
