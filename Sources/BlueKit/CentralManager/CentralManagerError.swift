import Foundation

/// High-level errors for `CentralManager` operations.
public enum CentralError: Error {
  /// An unknown error occurred.
  case unknown
  /// Bluetooth is powered off.
  case poweredOff
  /// The app is not authorized to use Bluetooth.
  case unauthorized
  /// Bluetooth is unavailable on this device.
  case unavailable
}

extension CentralError: LocalizedError {
  /// A human-readable description of the error.
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

  /// Suggestion to recover from this error.
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
