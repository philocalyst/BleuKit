import CoreBluetooth
import Dispatch
import Foundation

public class Peripheral: NSObject {
  private(set) var cbPeripheral: CBPeripheral
  private lazy var wrappedDelegate: PeripheralDelegateWrapper = .init(parent: self)

  internal let eventQueue = DispatchQueue(label: "peripheral-event-queue")
  internal lazy var responseMap = AsyncSubscriptionQueueMap<CBUUID, Result<Data, Error>>()
  internal lazy var writeMap = AsyncSubscriptionQueueMap<CBUUID, Error?>()
  internal lazy var descriptorMap = AsyncSubscriptionQueueMap<CBUUID, Result<Any?, Error>>()
  internal lazy var eventSubscriptions = AsyncSubscriptionQueue<PeripheralEvent>()

  internal var knownCharacteristics: [CBUUID: CBCharacteristic] = [:]

  internal var notifyingState = NotifyingTracker<CBUUID>()

  // MARK: - CBPeripheral properties
  public var name: String? { cbPeripheral.name }
  public var identifier: UUID { cbPeripheral.identifier }
  public var services: [CBService]? { cbPeripheral.services }
  public var state: CBPeripheralState { cbPeripheral.state }
  public var canSendWriteWithoutResponse: Bool { cbPeripheral.canSendWriteWithoutResponse }

  #if os(iOS)
    public var acnsAuthorized: Bool { cbPeripheral.ancsAuthorized }
  #endif

  public weak var delegate: PeripheralDelegate?

  public internal(set) var discovery: DiscoveryInfo!

  public subscript(dynamicMember member: KeyPath<Characteristic.Type, Characteristic>)
    -> CBCharacteristic?
  {
    let char = Characteristic.self[keyPath: member]
    return knownCharacteristics[char.uuid]
  }

  public func characteristic(for char: Characteristic) -> CBCharacteristic? {
    knownCharacteristics[char.uuid]
  }

  // MARK: - CBPeripheral initializers
  public init(_ cbPeripheral: CBPeripheral) {
    self.cbPeripheral = cbPeripheral
    super.init()

    cbPeripheral.delegate = wrappedDelegate
  }
}

// MARK: - CBPeripheral methods
extension Peripheral {
  public func discoverServices(_ serviceUUIDs: [CBUUID]?) {
    cbPeripheral.discoverServices(serviceUUIDs)
  }

  public func discoverIncludedServices(_ serviceUUIDs: [CBUUID]?, for service: CBService) {
    cbPeripheral.discoverIncludedServices(serviceUUIDs, for: service)
  }

  public func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: CBService) {
    cbPeripheral.discoverCharacteristics(characteristicUUIDs, for: service)
  }

  public func discoverDescriptors(for characteristic: CBCharacteristic) {
    cbPeripheral.discoverDescriptors(for: characteristic)
  }

  public func readValue(for characteristic: CBCharacteristic) {
    cbPeripheral.readValue(for: characteristic)
  }

  public func readValue(for descriptor: CBDescriptor) {
    cbPeripheral.readValue(for: descriptor)
  }

  public func writeValue(
    _ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType
  ) {
    cbPeripheral.writeValue(data, for: characteristic, type: type)
  }

  public func writeValue(_ data: Data, for descriptor: CBDescriptor) {
    cbPeripheral.writeValue(data, for: descriptor)
  }

  public func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int {
    cbPeripheral.maximumWriteValueLength(for: type)
  }

  public func setNotifyValue(_ value: Bool, for characteristic: CBCharacteristic) {
    // Keep track of if the user wants notifying values outside of our subscriptions
    let shouldNotify = notifyingState.setExternal(value, forKey: characteristic.uuid)

    cbPeripheral.setNotifyValue(shouldNotify, for: characteristic)
  }

  public func readRSSI() {
    cbPeripheral.readRSSI()
  }

  #if !os(macOS)
    @available(iOS 11.0, tvOS 11.0, watchOS 4.0, *)
    func openL2CAPChannel(_ PSM: CBL2CAPPSM) {
      cbPeripheral.openL2CAPChannel(PSM)
    }
  #endif
}
