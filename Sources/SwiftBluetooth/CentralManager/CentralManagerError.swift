import Foundation

public enum CentralError: Error {
  case unknown
  case poweredOff
  case unauthorized
  case unavailable
}

extension CentralError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .unknown:
      return "An unknown error occurred."
    case .poweredOff:
      return "Bluetooth is powered off."
    case .unauthorized:
      return "The app is not authorized to use Bluetooth."
    case .unavailable:
      return "Bluetooth is unavailable on this device."
    }
  }

  public var recoverySuggestion: String? {
    switch self {
    case .unknown:
      return "Try restarting Bluetooth or rebooting the device."
    case .poweredOff:
      return "Please enable Bluetooth in Settings."
    case .unauthorized:
      return "Grant Bluetooth permission in Settings → Privacy → Bluetooth."
    case .unavailable:
      return "Use a device that supports Bluetooth."
    }
  }
}
