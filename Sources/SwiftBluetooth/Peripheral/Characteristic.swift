import CoreBluetooth
import Foundation

/// Represents a CBCharacteristic UUID in a type-safe way.
public struct Characteristic: Hashable, Equatable, ExpressibleByStringLiteral, Sendable {
  /// The underlying CoreBluetooth UUID.
  public var uuid: CBUUID

  /// Creates a characteristic from a string UUID.
  ///
  /// - Parameter uuidString: The UUID string.
  init(_ uuidString: String) {
    self.uuid = .init(string: uuidString)
  }

  /// Creates a characteristic from a CoreBluetooth UUID.
  ///
  /// - Parameter cbUuid: The `CBUUID` instance.
  init(cbUuid: CBUUID) {
    self.uuid = cbUuid
  }

  /// Conformance to `ExpressibleByStringLiteral`.
  public init(stringLiteral value: StringLiteralType) {
    self.uuid = .init(string: value)
  }
}
