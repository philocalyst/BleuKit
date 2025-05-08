import CoreBluetooth
import Foundation

public struct Characteristic: Hashable, Equatable, ExpressibleByStringLiteral, Sendable {
  public var uuid: CBUUID

  init(_ uuidString: String) {
    self.uuid = .init(string: uuidString)
  }

  init(cbUuid: CBUUID) {
    self.uuid = cbUuid
  }

  public init(stringLiteral value: StringLiteralType) {
    self.uuid = .init(string: value)
  }
}
