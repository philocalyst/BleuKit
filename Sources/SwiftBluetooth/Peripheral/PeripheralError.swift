import CoreBluetooth
import Foundation

public enum PeripheralError: Error {
  case unknown
  case serviceNotFound(uuid: CBUUID)
  case characteristicNotFound(
    characteristicUUID: CBUUID)
  case descriptorNotFound(
    serviceUUID: CBUUID,
    characteristicUUID: CBUUID,
    descriptorUUID: CBUUID)
}

extension PeripheralError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .unknown:
      return "Unknown peripheral error."
    case .serviceNotFound(let uuid):
      return "Service \(uuid) not found on peripheral."
    case .characteristicNotFound(let cUUID):
      return "Characteristic \(cUUID) not found"
    case .descriptorNotFound(let sUUID, let cUUID, let dUUID):
      return """
        Descriptor \(dUUID) not found in characteristic \
        \(cUUID) of service \(sUUID).
        """
    }
  }
}
