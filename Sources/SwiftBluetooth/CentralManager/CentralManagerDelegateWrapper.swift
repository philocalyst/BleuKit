import CoreBluetooth
import Foundation

/// Internal wrapper that forwards CBCentralManagerDelegate callbacks
/// into our high-level `CentralManager` events and subscriptions.
internal final class CentralManagerDelegateWrapper: NSObject, CBCentralManagerDelegate {
  private weak var parent: CentralManager?

  /// Creates a new wrapper for a given `CentralManager`.
  ///
  /// - Parameter parent: The `CentralManager` instance.
  init(parent: CentralManager) {
    self.parent = parent
  }

  // MARK: - CBCentralManagerDelegate

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    guard let parent = parent else { return }
    parent.delegate?.centralManagerDidUpdateState(parent)
    parent.eventQueue.async {
      parent.eventSubscriptions.receive(.stateUpdated(parent.state))
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didConnect peripheral: CBPeripheral
  ) {
    guard let parent = parent else { return }
    let wrapper = parent.peripheral(peripheral)
    parent.connectedPeripherals.insert(wrapper)
    parent.delegate?.centralManager(parent, didConnect: wrapper)
    parent.eventQueue.async {
      parent.eventSubscriptions.receive(.connected(wrapper))
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral peripheral: CBPeripheral,
    error: Error?
  ) {
    guard let parent = parent else { return }
    let wrapper = parent.peripheral(peripheral)
    parent.connectedPeripherals.remove(wrapper)
    parent.delegate?.centralManager(
      parent,
      didDisconnectPeripheral: wrapper,
      error: error
    )
    parent.eventQueue.async {
      parent.eventSubscriptions.receive(.disconnected(wrapper, error))
      wrapper.eventSubscriptions.receive(.didDisconnect(error))
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didFailToConnect peripheral: CBPeripheral,
    error: Error?
  ) {
    guard let parent = parent else { return }
    let wrapper = parent.peripheral(peripheral)
    parent.delegate?.centralManager(parent, didFailToConnect: wrapper, error: error)
    parent.eventQueue.async {
      parent.eventSubscriptions.receive(.failToConnect(wrapper, error))
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    guard let parent = parent else { return }
    let wrapper = parent.peripheral(peripheral)
    wrapper.discovery = .init(rssi: RSSI, advertisementData: advertisementData)
    parent.delegate?.centralManager(
      parent,
      didDiscover: wrapper,
      advertisementData: advertisementData,
      rssi: RSSI
    )
    parent.eventQueue.async {
      parent.eventSubscriptions.receive(.discovered(wrapper, advertisementData, RSSI))
    }
  }

  func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
    guard let parent = parent else { return }
    parent.delegate?.centralManager(parent, willRestoreState: dict)
    parent.eventQueue.async {
      parent.eventSubscriptions.receive(.restoreState(dict))
    }
  }

  #if os(iOS)
    func centralManager(
      _ central: CBCentralManager,
      connectionEventDidOccur event: CBConnectionEvent,
      for peripheral: CBPeripheral
    ) {
      guard let parent = parent else { return }
      let wrapper = parent.peripheral(peripheral)
      parent.delegate?.centralManager(
        parent,
        connectionEventDidOccur: event,
        for: wrapper
      )
    }

    func centralManager(
      _ central: CBCentralManager,
      didUpdateANCSAuthorizationFor peripheral: CBPeripheral
    ) {
      guard let parent = parent else { return }
      let wrapper = parent.peripheral(peripheral)
      parent.delegate?.centralManager(
        parent,
        didUpdateANCSAuthorizationFor: wrapper
      )
    }
  #endif
}
