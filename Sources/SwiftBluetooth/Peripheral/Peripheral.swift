import CoreBluetooth
import Dispatch
import Foundation

/// High-level wrapper around CoreBluetooth’s `CBPeripheral`.
///
/// Manages delegate forwarding, event subscription queues, and
/// mapping between `CBUUID` and `CBCharacteristic`/`CBDescriptor`.
public class Peripheral: NSObject {
  /// Underlying CoreBluetooth peripheral.
  public var cbPeripheral: CBPeripheral

  /// Internal wrapper to forward CBPeripheralDelegate callbacks.
  private lazy var wrappedDelegate: PeripheralDelegateWrapper = .init(parent: self)

  /// Serial queue for peripheral events.
  internal let eventQueue = DispatchQueue(label: "peripheral-event-queue")

  /// Maps characteristic UUIDs to response queues.
  internal lazy var responseMap = AsyncSubscriptionQueueMap<CBUUID, Result<Data, Error>>()

  /// Maps characteristic UUIDs to write callbacks.
  internal lazy var writeMap = AsyncSubscriptionQueueMap<CBUUID, Error?>()

  /// Maps descriptor UUIDs to response queues.
  internal lazy var descriptorMap = AsyncSubscriptionQueueMap<CBUUID, Result<Any?, Error>>()

  /// Event subscription queue for peripheral-level events.
  internal lazy var eventSubscriptions = AsyncSubscriptionQueue<PeripheralEvent>()

  /// Known characteristics discovered on this peripheral.
  internal var knownCharacteristics: [CBUUID: CBCharacteristic] = [:]

  /// Tracks notify state for characteristics.
  internal var notifyingState = NotifyingTracker<CBUUID>()

  // MARK: - Public Properties

  /// Human-readable name of the peripheral.
  public var name: String? { cbPeripheral.name }

  /// Unique identifier of the peripheral.
  public var identifier: UUID { cbPeripheral.identifier }

  /// Services discovered on the peripheral.
  public var services: [CBService]? { cbPeripheral.services }

  /// Connection state of the peripheral.
  public var state: CBPeripheralState { cbPeripheral.state }

  /// Whether the peripheral can accept writes without response.
  public var canSendWriteWithoutResponse: Bool {
    cbPeripheral.canSendWriteWithoutResponse
  }

  #if os(iOS)
    /// ANCS (Apple Notification Center Service) authorization state.
    public var acnsAuthorized: Bool { cbPeripheral.ancsAuthorized }
  #endif

  /// Delegate to receive high-level peripheral events.
  public weak var delegate: PeripheralDelegate?

  /// Last discovery info (RSSI + advertisement).
  public internal(set) var discovery: DiscoveryInfo!

  /// Dynamically access known characteristics by static `Characteristic` key.
  public subscript(dynamicMember member: KeyPath<Characteristic.Type, Characteristic>)
    -> CBCharacteristic?
  {
    let c = Characteristic.self[keyPath: member]
    return knownCharacteristics[c.uuid]
  }

  /// Retrieve a characteristic by `Characteristic` value.
  ///
  /// - Parameter char: The typed `Characteristic`.
  /// - Returns: The mapped `CBCharacteristic`, if discovered.
  public func characteristic(for char: Characteristic) -> CBCharacteristic? {
    knownCharacteristics[char.uuid]
  }

  // MARK: - Initialization

  /// Wraps an existing `CBPeripheral`.
  ///
  /// - Parameter cbPeripheral: The CoreBluetooth peripheral.
  public init(_ cbPeripheral: CBPeripheral) {
    self.cbPeripheral = cbPeripheral
    super.init()
    cbPeripheral.delegate = wrappedDelegate
  }
}

// MARK: - Direct CBPeripheral Forwarding

extension Peripheral {
  /// Discover services.
  public func discoverServices(_ serviceUUIDs: [CBUUID]?) {
    cbPeripheral.discoverServices(serviceUUIDs)
  }

  /// Discover included services.
  public func discoverIncludedServices(
    _ serviceUUIDs: [CBUUID]?,
    for service: CBService
  ) {
    cbPeripheral.discoverIncludedServices(serviceUUIDs, for: service)
  }

  /// Discover characteristics.
  public func discoverCharacteristics(
    _ characteristicUUIDs: [CBUUID]?,
    for service: CBService
  ) {
    cbPeripheral.discoverCharacteristics(characteristicUUIDs, for: service)
  }

  /// Discover descriptors.
  public func discoverDescriptors(for characteristic: CBCharacteristic) {
    cbPeripheral.discoverDescriptors(for: characteristic)
  }

  /// Read a characteristic’s value.
  public func readValue(for characteristic: CBCharacteristic) {
    cbPeripheral.readValue(for: characteristic)
  }

  /// Read a descriptor’s value.
  public func readValue(for descriptor: CBDescriptor) {
    cbPeripheral.readValue(for: descriptor)
  }

  /// Write to a characteristic.
  public func writeValue(
    _ data: Data,
    for characteristic: CBCharacteristic,
    type: CBCharacteristicWriteType
  ) {
    cbPeripheral.writeValue(data, for: characteristic, type: type)
  }

  /// Write to a descriptor.
  public func writeValue(_ data: Data, for descriptor: CBDescriptor) {
    cbPeripheral.writeValue(data, for: descriptor)
  }

  /// Maximum write length for a given write type.
  public func maximumWriteValueLength(
    for type: CBCharacteristicWriteType
  ) -> Int {
    cbPeripheral.maximumWriteValueLength(for: type)
  }

  /// Set notify value without queueing.
  public func setNotifyValue(_ value: Bool, for characteristic: CBCharacteristic) {
    let should = notifyingState.setExternal(value, forKey: characteristic.uuid)
    cbPeripheral.setNotifyValue(should, for: characteristic)
  }

  /// Read RSSI.
  public func readRSSI() {
    cbPeripheral.readRSSI()
  }

  #if !os(macOS)
    /// Open L2CAP channel (iOS/tvOS/watchOS).
    public func openL2CAPChannel(_ PSM: CBL2CAPPSM) {
      cbPeripheral.openL2CAPChannel(PSM)
    }
  #endif
}
