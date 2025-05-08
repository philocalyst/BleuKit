import CoreBluetooth
import Foundation

/// Internal wrapper that forwards CBPeripheralDelegate callbacks
/// into our high-level `Peripheral` events and subscriptions.
internal final class PeripheralDelegateWrapper: NSObject, CBPeripheralDelegate {
  private weak var parent: Peripheral?

  /// Initialize with the high-level `Peripheral`.
  init(parent: Peripheral) {
    self.parent = parent
  }

  // MARK: - CBPeripheralDelegate

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard let p = parent else { return }
    p.eventSubscriptions.receive(.discoveredServices(p.services ?? [], error))
    p.delegate?.peripheral(p, didDiscoverServices: error)
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverIncludedServicesFor service: CBService,
    error: Error?
  ) {
    guard let p = parent else { return }
    p.delegate?.peripheral(
      p,
      didDiscoverIncludedServicesFor: service,
      error: error
    )
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverCharacteristicsFor service: CBService,
    error: Error?
  ) {
    guard let p = parent else { return }
    for ch in service.characteristics ?? [] {
      p.knownCharacteristics[ch.uuid] = ch
    }
    p.eventSubscriptions.receive(
      .discoveredCharacteristics(
        service,
        service.characteristics ?? [],
        error))
    p.delegate?.peripheral(
      p,
      didDiscoverCharacteristicsFor: service,
      error: error
    )
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverDescriptorsFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard let p = parent else { return }
    p.eventSubscriptions.receive(
      .discoveredDescriptors(
        characteristic,
        characteristic.descriptors ?? [],
        error))
    p.delegate?.peripheral(
      p,
      didDiscoverDescriptorsFor: characteristic,
      error: error
    )
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard let p = parent else { return }
    if let e = error {
      p.responseMap.receive(
        key: characteristic.uuid,
        withValue: .failure(e))
    } else if let v = characteristic.value {
      p.responseMap.receive(
        key: characteristic.uuid,
        withValue: .success(v))
    }
    p.delegate?.peripheral(
      p,
      didUpdateValueFor: characteristic,
      error: error
    )
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor descriptor: CBDescriptor,
    error: Error?
  ) {
    guard let p = parent else { return }
    if let e = error {
      p.descriptorMap.receive(
        key: descriptor.uuid,
        withValue: .failure(e))
    } else {
      p.descriptorMap.receive(
        key: descriptor.uuid,
        withValue: .success(descriptor.value))
    }
    p.delegate?.peripheral(
      p,
      didUpdateValueFor: descriptor,
      error: error
    )
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didWriteValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard let p = parent else { return }
    p.writeMap.receive(
      key: characteristic.uuid,
      withValue: error)
    p.delegate?.peripheral(
      p,
      didWriteValueFor: characteristic,
      error: error
    )
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didWriteValueFor descriptor: CBDescriptor,
    error: Error?
  ) {
    guard let p = parent else { return }
    p.writeMap.receive(
      key: descriptor.uuid,
      withValue: error)
    p.delegate?.peripheral(
      p,
      didWriteValueFor: descriptor,
      error: error
    )
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard let p = parent else { return }
    p.eventSubscriptions.receive(.updateNotificationState(characteristic, error))
    p.delegate?.peripheral(
      p,
      didUpdateNotificationStateFor: characteristic,
      error: error
    )
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didReadRSSI RSSI: NSNumber,
    error: Error?
  ) {
    guard let p = parent else { return }
    p.eventSubscriptions.receive(.readRSSI(RSSI, error))
    p.delegate?.peripheral(
      p,
      didReadRSSI: RSSI,
      error: error
    )
  }

  func peripheral(_ peripheral: CBPeripheral, didModifyServices services: [CBService]) {
    guard let p = parent else { return }
    p.delegate?.peripheral(p, didModifyServices: services)
  }

  func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
    guard let p = parent else { return }
    p.delegate?.peripheralDidUpdateName(p)
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didOpen channel: CBL2CAPChannel?,
    error: Error?
  ) {
    guard let p = parent else { return }
    p.delegate?.peripheral(p, didOpen: channel, error: error)
  }
}
