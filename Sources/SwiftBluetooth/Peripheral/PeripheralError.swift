import CoreBluetooth
import Foundation

/// Errors thrown by high-level `Peripheral` APIs.
public enum PeripheralError: Error {
  /// An unknown error occurred.
  case unknown
  /// A requested service was not found on the peripheral.
  case serviceNotFound(uuid: CBUUID)
  /// A requested characteristic was not found.
  case characteristicNotFound(characteristicUUID: CBUUID)
  /// A requested descriptor was not found.
  case descriptorNotFound(
    serviceUUID: CBUUID,
    characteristicUUID: CBUUID,
    descriptorUUID: CBUUID
  )
}

extension PeripheralError: LocalizedError {
  /// A human-readable description of the error.
  public var errorDescription: String? {
    switch self {
    case .unknown:
      return "Unknown peripheral error."
    case .serviceNotFound(let uuid):
      return "Service \(uuid) not found on peripheral."
    case .characteristicNotFound(let cUUID):
      return "Characteristic \(cUUID) not found."
    case .descriptorNotFound(let sUUID, let cUUID, let dUUID):
      return """
        Descriptor \(dUUID) not found in characteristic \
        \(cUUID) of service \(sUUID).
        """
    }
  }
}
