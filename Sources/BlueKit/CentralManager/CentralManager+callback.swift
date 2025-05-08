import CoreBluetooth
import Dispatch
import Foundation

/// Represents a discovered peripheral along with advertisement data and RSSI.
public struct PeripheralScanResult {
  /// The discovered `Peripheral` wrapper.
  public let peripheral: Peripheral
  /// Raw advertisement data dictionary.
  public let advertisementData: [String: Any]
  /// The received signal strength indicator.
  public let rssi: NSNumber
}

extension CentralManager {
  /// Blocks until the central manager’s state becomes `.poweredOn`, `.unauthorized`, or `.unsupported`.
  ///
  /// - Parameters:
  ///   - timeout: Maximum time to wait before failing with `.poweredOff`.
  ///   - completionHandler: Called with `.success(())` when ready or
  ///     `.failure(Error)` on error or timeout.
  public func waitUntilReady(
    timeout: TimeInterval = Double.infinity,
    completionHandler: @escaping (Result<Void, Error>) -> Void
  ) {
    eventQueue.async { [self] in
      guard state != .poweredOn else {
        completionHandler(.success(Void()))
        return
      }
      guard state != .unauthorized else {
        completionHandler(.failure(CentralError.unauthorized))
        return
      }
      guard state != .unsupported else {
        completionHandler(.failure(CentralError.unavailable))
        return
      }

      var timer: Timer?
      let task = eventSubscriptions.queue { event, done in
        guard case .stateUpdated(let state) = event else { return }

        switch state {
        case .poweredOn:
          completionHandler(.success(Void()))
        case .unauthorized:
          completionHandler(.failure(CentralError.unauthorized))
        case .unsupported:
          completionHandler(.failure(CentralError.unavailable))
        default:
          return
        }

        timer?.invalidate()
        done()
      }

      if timeout != .infinity {
        let timeoutTimer = Timer(
          fire: Date() + timeout, interval: 0,
          repeats: false
        ) { _ in
          task.cancel()
          completionHandler(.failure(CentralError.poweredOff))
        }
        timer = timeoutTimer
        RunLoop.main.add(timeoutTimer, forMode: .default)
      }
    }
  }

  /// Initiates a connection to the specified peripheral, with a timeout.
  ///
  /// - Parameters:
  ///   - peripheral: The `Peripheral` to connect to.
  ///   - timeout: Maximum time to wait before timing out with
  ///     `CBError(.connectionTimeout)`.
  ///   - options: Connection options dictionary.
  ///   - completionHandler: Called with `.success(peripheral)` on success or
  ///     `.failure(Error)` on failure.
  public func connect(
    _ peripheral: Peripheral,
    timeout: TimeInterval,
    options: [String: Any]? = nil,
    completionHandler: @escaping (Result<Peripheral, Error>) -> Void
  ) {
    eventQueue.async { [self] in
      guard peripheral.state != .connected else {
        completionHandler(.success(peripheral))
        return
      }

      var timer: Timer?
      let task = eventSubscriptions.queue { event, done in
        switch event {
        case .connected(let connected):
          guard connected == peripheral else { return }
          completionHandler(.success(peripheral))
        case .disconnected(let disconnected, let error):
          guard disconnected == peripheral else { return }
          completionHandler(.failure(error ?? CentralError.unknown))
        case .failToConnect(let failed, let error):
          guard failed == peripheral else { return }
          completionHandler(.failure(error ?? CentralError.unknown))
        default:
          return
        }

        timer?.invalidate()
        done()
      }

      if timeout != .infinity {
        let timeoutTimer = Timer(
          fire: Date() + timeout, interval: 0,
          repeats: false
        ) { _ in
          task.cancel()
          completionHandler(.failure(CBError(.connectionTimeout)))
        }
        timer = timeoutTimer
        RunLoop.main.add(timeoutTimer, forMode: .default)
      }

      connect(peripheral, options: options)
    }
  }

  /// Scans for peripherals advertising the specified services.
  ///
  /// - Parameters:
  ///   - services: Array of `CBUUID` to filter by (or `nil` for all).
  ///   - timeout: Optional scan timeout; `nil` or `.infinity` means no timeout.
  ///   - options: CoreBluetooth scan options.
  ///   - onPeripheralFound: Closure invoked for each discovered peripheral.
  /// - Returns: A `CancellableTask` that cancels the scan when `cancel()` is called.
  public func scanForPeripherals(
    withServices services: [CBUUID]? = nil,
    timeout: TimeInterval? = nil,
    options: [String: Any]? = nil,
    onPeripheralFound: @escaping (PeripheralScanResult) -> Void
  ) -> CancellableTask {
    eventQueue.sync {
      var timer: Timer?
      let subscription = eventSubscriptions.queue { event, done in
        switch event {
        case .discovered(let peripheral, let advData, let rssi):
          onPeripheralFound(
            PeripheralScanResult(
              peripheral: peripheral,
              advertisementData: advData,
              rssi: rssi))
        case .stopScan:
          done()
        default:
          break
        }
      } completion: { [weak self, timer] in
        guard let self = self else { return }
        timer?.invalidate()
        self.centralManager.stopScan()
      }

      if timeout != .infinity {
        if let timeout = timeout {
          let timeoutTimer = Timer(
            fire: Date() + timeout, interval: 0,
            repeats: false
          ) { _ in
            subscription.cancel()
          }
          timer = timeoutTimer
          RunLoop.main.add(timeoutTimer, forMode: .default)
        }
      }

      centralManager.scanForPeripherals(withServices: services, options: options)
      return subscription
    }
  }

  /// Cancels an active or pending connection to the specified peripheral.
  ///
  /// - Parameters:
  ///   - peripheral: The `Peripheral` to disconnect.
  ///   - completionHandler: Called with `.success(())` if already disconnected
  ///     or on disconnect, or `.failure(Error)` if an error occurs.
  public func cancelPeripheralConnection(
    _ peripheral: Peripheral,
    completionHandler: @escaping (Result<Void, Error>) -> Void
  ) {
    eventQueue.async { [self] in
      guard connectedPeripherals.contains(peripheral) else {
        completionHandler(.success(Void()))
        return
      }

      eventSubscriptions.queue { event, done in
        guard case .disconnected(let disconnected, let error) = event,
          disconnected == peripheral
        else { return }

        if let error = error {
          completionHandler(.failure(error))
        } else {
          completionHandler(.success(Void()))
        }
        done()
      }

      cancelPeripheralConnection(peripheral)
    }
  }
}
