import CoreBluetooth
import Dispatch
import Foundation

public protocol CentralManagerDelegate: AnyObject {
  func centralManagerDidUpdateState(_ central: CentralManager)
  func centralManager(_ central: CentralManager, didConnect peripheral: Peripheral)
  func centralManager(
    _ central: CentralManager, didDisconnectPeripheral peripheral: Peripheral, error: Error?)
  func centralManager(
    _ central: CentralManager, didFailToConnect peripheral: Peripheral, error: Error?)
  func centralManager(
    _ central: CentralManager, connectionEventDidOccur event: CBConnectionEvent,
    for peripheral: Peripheral)
  func centralManager(
    _ central: CentralManager, didDiscover peripheral: Peripheral, advertisementData: [String: Any],
    rssi RSSI: NSNumber)
  func centralManager(_ central: CentralManager, willRestoreState dict: [String: Any])
  func centralManager(
    _ central: CentralManager, didUpdateANCSAuthorizationFor peripheral: Peripheral)
}

// Default values
extension CentralManagerDelegate {
  public func centralManagerDidUpdateState(_ central: CentralManager) {}
  public func centralManager(_ central: CentralManager, didConnect peripheral: Peripheral) {}
  public func centralManager(
    _ central: CentralManager, didDisconnectPeripheral peripheral: Peripheral, error: Error?
  ) {}
  public func centralManager(
    _ central: CentralManager, didFailToConnect peripheral: Peripheral, error: Error?
  ) {}
  public func centralManager(
    _ central: CentralManager, connectionEventDidOccur event: CBConnectionEvent,
    for peripheral: Peripheral
  ) {}
  public func centralManager(
    _ central: CentralManager, didDiscover peripheral: Peripheral, advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {}
  public func centralManager(_ central: CentralManager, willRestoreState dict: [String: Any]) {}
  public func centralManager(
    _ central: CentralManager, didUpdateANCSAuthorizationFor peripheral: Peripheral
  ) {}
}
