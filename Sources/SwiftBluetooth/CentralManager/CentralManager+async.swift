import CoreBluetooth
import Foundation

extension CentralManager {
  /// Suspends until the central manager’s state becomes `.poweredOn`,
  /// or throws if the timeout elapses first.
  ///
  /// - Parameter timeout: Maximum time to wait before throwing `.poweredOff`.
  /// - Throws: `CentralError` (poweredOff, unauthorized, unavailable) or cancellation.
  @available(iOS 13, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
  public func waitUntilReady(timeout: TimeInterval = .infinity) async throws {
    try await withCheckedThrowingContinuation { cont in
      self.waitUntilReady(timeout: timeout) { result in
        cont.resume(with: result)
      }
    }
  }

  /// Asynchronously connects to `peripheral`, respecting `timeout`,
  /// and returns the connected peripheral or throws on error.
  ///
  /// - Parameters:
  ///   - peripheral: The `Peripheral` to connect.
  ///   - timeout: Maximum time to wait before timing out.
  ///   - options: Connection options dictionary.
  /// - Returns: The same `Peripheral` on success.
  /// - Throws: `CancellationError`, `CBError(.connectionTimeout)`, or other errors.
  @available(iOS 13, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
  @discardableResult
  public func connect(
    _ peripheral: Peripheral,
    timeout: TimeInterval,
    options: [String: Any]? = nil
  ) async throws -> Peripheral {
    var cancelled = false
    var continuation: CheckedContinuation<Peripheral, Error>?
    let cancel = {
      cancelled = true
      self.cancelPeripheralConnection(peripheral)
      continuation?.resume(throwing: CancellationError())
    }

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { cont in
        continuation = cont
        guard !cancelled else {
          cancel()
          return
        }
        self.connect(peripheral, timeout: timeout, options: options) { result in
          guard !cancelled else { return }
          cont.resume(with: result)
        }
      }
    } onCancel: {
      cancel()
    }
  }

  /// Scans for peripherals advertising the specified services and
  /// returns an `AsyncStream` of discovery events.
  ///
  /// - Parameters:
  ///   - services: Array of `CBUUID` to filter by (or `nil` for all).
  ///   - timeout: Optional scan timeout; `nil` means “no timeout”.
  ///   - options: Scan options dictionary.
  /// - Returns: An `AsyncStream<PeripheralScanResult>` yielding discoveries
  ///            until `.stopScan` is received or timeout.
  @available(iOS 13, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
  public func scanForPeripherals(
    withServices services: [CBUUID]? = nil,
    timeout: TimeInterval? = nil,
    options: [String: Any]? = nil
  ) async -> AsyncStream<PeripheralScanResult> {
    .init { cont in
      var timer: Timer?
      let subscription = eventSubscriptions.queue { event, done in
        switch event {
        case .discovered(let peripheral, let advData, let rssi):
          cont.yield(
            PeripheralScanResult(peripheral: peripheral, advertisementData: advData, rssi: rssi)
          )
        case .stopScan:
          done()
          cont.finish()
        default:
          break
        }
      } completion: { [weak self] in
        guard let self = self else { return }
        timer?.invalidate()
        self.centralManager.stopScan()
      }

      if let timeout = timeout {
        let timeoutTimer = Timer(fire: Date() + timeout, interval: 0, repeats: false) { _ in
          subscription.cancel()
          cont.finish()
        }
        timer = timeoutTimer
        RunLoop.main.add(timeoutTimer, forMode: .default)
      }

      cont.onTermination = { _ in
        subscription.cancel()
      }

      centralManager.scanForPeripherals(withServices: services, options: options)
    }
  }

  /// Asynchronously cancels a pending connection to `peripheral`.
  /// - Parameter peripheral: The `Peripheral` to disconnect.
  /// - Throws: Error if cancellation fails.
  @available(iOS 13, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
  public func cancelPeripheralConnection(_ peripheral: Peripheral) async throws {
    try await withCheckedThrowingContinuation { cont in
      self.cancelPeripheralConnection(peripheral) { result in
        cont.resume(with: result)
      }
    }
  }
}
