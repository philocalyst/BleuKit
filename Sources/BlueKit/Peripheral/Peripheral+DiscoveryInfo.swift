import CoreBluetooth
import Foundation

extension Peripheral {
  /// Information discovered during scanning: RSSI and advertisement.
  public struct DiscoveryInfo {
    /// Received signal strength.
    public var rssi: Int
    /// Parsed advertisement data.
    public var advertisementData: AdvertisementData

    init(rssi: NSNumber, advertisementData: [String: Any]) {
      self.rssi = Int(truncating: rssi)
      self.advertisementData = .init(data: advertisementData)
    }

    /// Wrapper around the raw advertisement dictionary.
    public struct AdvertisementData {
      private(set) var data: [String: Any]

      /// Access raw field by key.
      public subscript(key: String) -> Any? { data[key] }

      /// The local name of the peripheral, if advertised.
      public var localName: String? {
        data[CBAdvertisementDataLocalNameKey] as? String
      }
      /// Manufacturer data, if advertised.
      public var manufacturerData: Data? {
        data[CBAdvertisementDataManufacturerDataKey] as? Data
      }
      /// Service-specific data.
      public var serviceData: [CBUUID: Data] {
        data[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
      }
      /// List of advertised service UUIDs.
      public var serviceUUIDs: [CBUUID] {
        data[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
      }
      /// Overflow service UUIDs.
      public var overflowServiceUUIDs: [CBUUID] {
        data[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
      }
      /// Transmit power level.
      public var txPowerLevel: Int? {
        (data[CBAdvertisementDataTxPowerLevelKey] as? NSNumber).map { Int(truncating: $0) }
      }
      /// Whether the peripheral is connectable.
      public var isConnectable: Bool? {
        (data[CBAdvertisementDataIsConnectable] as? NSNumber).map { Bool(truncating: $0) }
      }
      /// Solicited service UUIDs.
      public var solicitedServiceUUIDs: [CBUUID] {
        data[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID] ?? []
      }
    }
  }
}
