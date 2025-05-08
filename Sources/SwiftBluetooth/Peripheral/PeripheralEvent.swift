import CoreBluetooth
import Foundation

/// Internal events emitted by `PeripheralDelegateWrapper`
/// and consumed by `AsyncSubscriptionQueue<PeripheralEvent>`.
internal enum PeripheralEvent {
  /// Services were discovered.
  case discoveredServices([CBService], Error?)
  /// Characteristics were discovered for a service.
  case discoveredCharacteristics(
    CBService,
    [CBCharacteristic],
    Error?
  )
  /// Descriptors were discovered for a characteristic.
  case discoveredDescriptors(
    CBCharacteristic,
    [CBDescriptor],
    Error?
  )
  /// Notification state changed for a characteristic.
  case updateNotificationState(CBCharacteristic, Error?)
  /// RSSI was read.
  case readRSSI(NSNumber, Error?)
  /// L2CAP channel opened (iOS/tvOS/watchOS).
  case didOpenL2CAPChannel(CBL2CAPChannel?, Error?)
  /// The peripheral disconnected.
  case didDisconnect(Error?)
}
