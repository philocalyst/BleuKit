import CoreBluetooth
import Dispatch
import Foundation

/// High‐level Bluetooth central manager that wraps CoreBluetooth’s `CBCentralManager`.
///
/// Provides both callback‐based and async/await APIs for scanning, connecting,
/// and state updates.
public class CentralManager: NSObject {
  /// Underlying CoreBluetooth manager (real or mock).
  private(set) var centralManager: CBCentralManager

  /// Internal wrapper to forward `CBCentralManagerDelegate` callbacks.
  private lazy var wrappedDelegate: CentralManagerDelegateWrapper = .init(parent: self)

  /// Serial queue for processing central‐manager events.
  internal let eventQueue = DispatchQueue(label: "centralmanager-event-queue")

  /// Event subscription queue for external listeners.
  internal lazy var eventSubscriptions = AsyncSubscriptionQueue<CentralManagerEvent>()

  /// Maps CBPeripheral identifiers to their `Peripheral` wrappers.
  private var peripheralMap: [UUID: Peripheral] = [:]

  /// Tracks currently connected peripherals.
  internal var connectedPeripherals = Set<Peripheral>()

  // MARK: - Public Properties

  /// Delegate to receive high‐level central manager events.
  public weak var delegate: CentralManagerDelegate?

  /// Current Bluetooth state of the manager.
  public var state: CBManagerState { centralManager.state }

  /// Whether the manager is currently scanning.
  public var isScanning: Bool { centralManager.isScanning }

  /// Deprecated on iOS 13.1+ – use `CBCentralManager.authorization`.
  @available(iOS, deprecated: 13.1)
  public var authorization: CBManagerAuthorization { centralManager.authorization }

  // MARK: - Initialization

  /// Creates a new central manager (uses mock by default for tests).
  override init() {
    centralManager = CBCentralManagerFactory.instance(
      delegate: nil,
      queue: nil,
      forceMock: true
    )
    super.init()
    centralManager.delegate = wrappedDelegate
  }

  /// Creates a new central manager with the provided delegate, queue, and options.
  ///
  /// - Parameters:
  ///   - delegate: High‐level delegate for central events.
  ///   - queue: Dispatch queue for CoreBluetooth callbacks.
  ///   - options: CoreBluetooth initialization options.
  public init(
    delegate: CentralManagerDelegate? = nil,
    queue: DispatchQueue? = nil,
    options: [String: Any]? = nil
  ) {
    self.delegate = delegate
    centralManager = CBCentralManagerFactory.instance(
      delegate: nil,
      queue: queue,
      options: options,
      forceMock: true
    )
    super.init()
    centralManager.delegate = wrappedDelegate
  }

  // MARK: - Internal Helpers

  /// Returns or creates a `Peripheral` wrapper for a given `CBPeripheral`.
  ///
  /// - Parameter cbPeripheral: The CoreBluetooth peripheral to wrap.
  /// - Returns: The corresponding `Peripheral` instance.
  internal func peripheral(_ cbPeripheral: CBPeripheral) -> Peripheral {
    if let existing = peripheralMap[cbPeripheral.identifier] {
      return existing
    }
    let wrapper = Peripheral(cbPeripheral)
    peripheralMap[cbPeripheral.identifier] = wrapper
    // Guarantee we return exactly the instance we stored.
    return peripheral(cbPeripheral)
  }

  /// Removes the wrapper for a given `CBPeripheral`.
  ///
  /// - Parameter cbPeripheral: The peripheral to remove.
  internal func removePeripheral(_ cbPeripheral: CBPeripheral) {
    peripheralMap.removeValue(forKey: cbPeripheral.identifier)
  }
}

// MARK: - Public API Forwarding to CoreBluetooth

extension CentralManager {
  /// Connects to a peripheral immediately.
  ///
  /// - Parameters:
  ///   - peripheral: The `Peripheral` to connect.
  ///   - options: CoreBluetooth connect options.
  public func connect(_ peripheral: Peripheral, options: [String: Any]? = nil) {
    centralManager.connect(peripheral.cbPeripheral, options: options)
  }

  /// Cancels any outstanding or active connection to a peripheral.
  ///
  /// - Parameter peripheral: The `Peripheral` to disconnect.
  public func cancelPeripheralConnection(_ peripheral: Peripheral) {
    centralManager.cancelPeripheralConnection(peripheral.cbPeripheral)
  }

  /// Retrieves currently connected peripherals matching the given services.
  ///
  /// - Parameter services: Array of `CBUUID` to filter by.
  /// - Returns: Array of `Peripheral` wrappers.
  public func retrieveConnectedPeripherals(withServices services: [CBUUID]) -> [Peripheral] {
    centralManager.retrieveConnectedPeripherals(withServices: services)
      .map(peripheral(_:))
  }

  /// Retrieves peripherals by their UUID identifiers.
  ///
  /// - Parameter identifiers: Array of peripheral `UUID`s.
  /// - Returns: Array of `Peripheral` wrappers.
  public func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [Peripheral] {
    centralManager.retrievePeripherals(withIdentifiers: identifiers)
      .map(peripheral(_:))
  }

  /// Starts scanning for peripherals advertising the given services.
  ///
  /// - Parameters:
  ///   - services: Optional service UUID filters.
  ///   - options: CoreBluetooth scan options.
  public func scanForPeripherals(
    withServices services: [CBUUID]?,
    options: [String: Any]? = nil
  ) {
    centralManager.scanForPeripherals(withServices: services, options: options)
  }

  /// Stops an ongoing scan and notifies subscribers.
  public func stopScan() {
    eventSubscriptions.receive(.stopScan)
    centralManager.stopScan()
  }
}
