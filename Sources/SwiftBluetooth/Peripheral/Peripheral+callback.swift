import CoreBluetooth
import Dispatch
import Foundation

extension Peripheral {
  /// Read a characteristic’s value via callback.
  ///
  /// - Parameters:
  ///   - characteristic: The `CBCharacteristic` to read.
  ///   - completionHandler: Called with `.success(data)` or `.failure(error)`.
  public func readValue(
    for characteristic: CBCharacteristic,
    completionHandler: @escaping (Result<Data, Error>) -> Void
  ) {
    eventQueue.async { [self] in
      guard state == .connected else {
        completionHandler(.failure(CBError(.peripheralDisconnected)))
        return
      }
      var readTask: AsyncSubscription<Result<Data, Error>>?
      var disconnectTask: AsyncSubscription<PeripheralEvent>?

      readTask = responseMap.queue(key: characteristic.uuid) { result, done in
        completionHandler(result)
        disconnectTask?.cancel()
        done()
      }

      disconnectTask = eventSubscriptions.queue { event, done in
        guard case .didDisconnect(let err) = event else { return }
        completionHandler(.failure(err ?? CBError(.peripheralDisconnected)))
        readTask?.cancel()
        done()
      }

      readValue(for: characteristic)
    }
  }

  /// Read a typed `Characteristic` via callback.
  ///
  /// - Parameters:
  ///   - characteristic: The typed `Characteristic`.
  ///   - completionHandler: Called with `.success(data)` or `.failure(error)`.
  public func readValue(
    for characteristic: Characteristic,
    completionHandler: @escaping (Result<Data, Error>) -> Void
  ) {
    guard let cb = knownCharacteristics[characteristic.uuid] else { return }
    readValue(for: cb, completionHandler: completionHandler)
  }

  /// Read a descriptor’s value via callback.
  ///
  /// - Parameters:
  ///   - descriptor: The `CBDescriptor` to read.
  ///   - completionHandler: Called with `.success(value)` or `.failure(error)`.
  public func readValue(
    for descriptor: CBDescriptor,
    completionHandler: @escaping (Result<Any?, Error>) -> Void
  ) {
    eventQueue.async { [self] in
      guard state == .connected else {
        completionHandler(.failure(CBError(.peripheralDisconnected)))
        return
      }
      var readTask: AsyncSubscription<Result<Any?, Error>>?
      var disconnectTask: AsyncSubscription<PeripheralEvent>?

      readTask = descriptorMap.queue(key: descriptor.uuid) { result, done in
        completionHandler(result)
        disconnectTask?.cancel()
        done()
      }

      disconnectTask = eventSubscriptions.queue { event, done in
        guard case .didDisconnect(let err) = event else { return }
        completionHandler(.failure(err ?? CBError(.peripheralDisconnected)))
        readTask?.cancel()
        done()
      }

      readValue(for: descriptor)
    }
  }

  /// Subscribe to notification updates via callback.
  ///
  /// - Parameters:
  ///   - characteristic: The notifying `CBCharacteristic`.
  ///   - onValueUpdate: Called for each data update.
  /// - Returns: A `CancellableTask` to stop notifications.
  public func readValues(
    for characteristic: CBCharacteristic,
    onValueUpdate: @escaping (Data) -> Void
  ) -> CancellableTask {
    eventQueue.sync {
      var dataTask: AsyncSubscription<Result<Data, Error>>?
      let stateTask = eventSubscriptions.queue { event, done in
        if case .didDisconnect = event {
          done()
          return
        }
        guard case .updateNotificationState(let ch, let err) = event,
          ch.uuid == characteristic.uuid,
          !ch.isNotifying || err != nil
        else { return }
        done()
      } completion: {
        dataTask?.cancel()
      }

      dataTask = responseMap.queue(key: characteristic.uuid) { result, done in
        switch result {
        case .success(let d): onValueUpdate(d)
        case .failure:
          stateTask.cancel()
          done()
        }
      } completion: { [weak self] in
        guard let self = self else { return }
        let keepOn = self.notifyingState.removeInternal(forKey: characteristic.uuid)
        self.cbPeripheral.setNotifyValue(keepOn, for: characteristic)
      }

      notifyingState.addInternal(forKey: characteristic.uuid)
      cbPeripheral.setNotifyValue(true, for: characteristic)
      return stateTask
    }
  }

  /// Write a characteristic’s value via callback.
  ///
  /// - Parameters:
  ///   - data: The `Data` to write.
  ///   - characteristic: The `CBCharacteristic`.
  ///   - type: The write type.
  ///   - completionHandler: Called with `nil` on success or an `Error`.
  public func writeValue(
    _ data: Data,
    for characteristic: CBCharacteristic,
    type: CBCharacteristicWriteType,
    completionHandler: @escaping (Error?) -> Void
  ) {
    eventQueue.async { [self] in
      guard state == .connected else {
        completionHandler(CBError(.peripheralDisconnected))
        return
      }
      if type == .withResponse {
        var writeTask: AsyncSubscription<Error?>?
        var disconnectTask: AsyncSubscription<PeripheralEvent>?

        writeTask = writeMap.queue(key: characteristic.uuid) { error, done in
          completionHandler(error)
          disconnectTask?.cancel()
          done()
        }

        disconnectTask = eventSubscriptions.queue { event, done in
          guard case .didDisconnect(let err) = event else { return }
          completionHandler(err ?? CBError(.peripheralDisconnected))
          writeTask?.cancel()
          done()
        }
      }
      writeValue(data, for: characteristic, type: type)
      if type == .withoutResponse {
        completionHandler(nil)
      }
    }
  }

  /// Write a descriptor’s value via callback.
  ///
  /// - Parameters:
  ///   - data: The `Data` to write.
  ///   - descriptor: The `CBDescriptor`.
  ///   - completionHandler: Called with `nil` on success or an `Error`.
  public func writeValue(
    _ data: Data,
    for descriptor: CBDescriptor,
    completionHandler: @escaping (Error?) -> Void
  ) {
    eventQueue.async { [self] in
      writeMap.queue(key: descriptor.uuid) { error, done in
        completionHandler(error)
        done()
      }
      writeValue(data, for: descriptor)
    }
  }

  /// Discover services via callback.
  ///
  /// - Parameters:
  ///   - serviceUUIDs: Array of `CBUUID` or `nil`.
  ///   - completionHandler: Called with `.success(services)` or `.failure(error)`.
  public func discoverServices(
    _ serviceUUIDs: [CBUUID]? = nil,
    completionHandler: @escaping (Result<[CBService], Error>) -> Void
  ) {
    eventQueue.async { [self] in
      guard state == .connected else {
        completionHandler(.failure(CBError(.peripheralDisconnected)))
        return
      }
      eventSubscriptions.queue { event, done in
        if case .didDisconnect(let err) = event {
          completionHandler(.failure(err ?? CBError(.peripheralDisconnected)))
          done()
          return
        }
        guard case .discoveredServices(let svcs, let err) = event else { return }
        defer { done() }
        if let e = err { completionHandler(.failure(e)) } else { completionHandler(.success(svcs)) }
      }
      discoverServices(serviceUUIDs)
    }
  }

  /// Discover characteristics via callback.
  ///
  /// - Parameters:
  ///   - characteristicUUIDs: Array of `CBUUID` or `nil`.
  ///   - service: The `CBService`.
  ///   - completionHandler: Called with `.success(chars)` or `.failure(error)`.
  public func discoverCharacteristics(
    _ characteristicUUIDs: [CBUUID]? = nil,
    for service: CBService,
    completionHandler: @escaping (Result<[CBCharacteristic], Error>) -> Void
  ) {
    eventQueue.async { [self] in
      guard state == .connected else {
        completionHandler(.failure(CBError(.peripheralDisconnected)))
        return
      }
      eventSubscriptions.queue { event, done in
        if case .didDisconnect(let err) = event {
          completionHandler(.failure(err ?? CBError(.peripheralDisconnected)))
          done()
          return
        }
        guard case .discoveredCharacteristics(let svc, let chars, let err) = event,
          svc.uuid == service.uuid
        else { return }
        defer { done() }
        if let e = err {
          completionHandler(.failure(e))
        } else {
          completionHandler(.success(chars))
        }
      }
      discoverCharacteristics(characteristicUUIDs, for: service)
    }
  }

  /// Discover descriptors via callback.
  ///
  /// - Parameters:
  ///   - characteristic: The `CBCharacteristic`.
  ///   - completionHandler: Called with `.success(descs)` or `.failure(error)`.
  public func discoverDescriptors(
    for characteristic: CBCharacteristic,
    completionHandler: @escaping (Result<[CBDescriptor], Error>) -> Void
  ) {
    eventQueue.async { [self] in
      guard state == .connected else {
        completionHandler(.failure(CBError(.peripheralDisconnected)))
        return
      }
      eventSubscriptions.queue { event, done in
        if case .didDisconnect(let err) = event {
          completionHandler(.failure(err ?? CBError(.peripheralDisconnected)))
          done()
          return
        }
        guard case .discoveredDescriptors(let ch, let descs, let err) = event,
          ch.uuid == characteristic.uuid
        else { return }
        defer { done() }
        if let e = err {
          completionHandler(.failure(e))
        } else {
          completionHandler(.success(descs))
        }
      }
      discoverDescriptors(for: characteristic)
    }
  }

  /// Set notification state via callback.
  ///
  /// - Parameters:
  ///   - value: `true` to enable, `false` to disable.
  ///   - characteristic: The `CBCharacteristic`.
  ///   - completionHandler: Called with `.success(isNotifying)` or `.failure(error)`.
  public func setNotifyValue(
    _ value: Bool,
    for characteristic: CBCharacteristic,
    completionHandler: @escaping (Result<Bool, Error>) -> Void
  ) {
    eventQueue.async { [self] in
      let should = notifyingState.setExternal(value, forKey: characteristic.uuid)
      guard state == .connected else {
        completionHandler(.failure(CBError(.peripheralDisconnected)))
        return
      }
      guard characteristic.isNotifying != should else {
        completionHandler(.success(value))
        return
      }
      eventSubscriptions.queue { event, done in
        if case .didDisconnect(let err) = event {
          completionHandler(.failure(err ?? CBError(.peripheralDisconnected)))
          done()
          return
        }
        guard case .updateNotificationState(let ch, let err) = event,
          ch.uuid == characteristic.uuid
        else { return }
        defer { done() }
        if let e = err {
          completionHandler(.failure(e))
        } else {
          completionHandler(.success(ch.isNotifying))
        }
      }
      cbPeripheral.setNotifyValue(should, for: characteristic)
    }
  }

  /// Typed `Characteristic` version of setNotifyValue(_:for:).
  ///
  /// - Parameters:
  ///   - value: `true` to enable, `false` to disable.
  ///   - characteristic: The typed `Characteristic`.
  /// - Throws: If characteristic not found.
  public func setNotifyValue(
    _ value: Bool,
    for characteristic: Characteristic
  ) throws {
    guard let cb = knownCharacteristics[characteristic.uuid] else {
      throw PeripheralError.characteristicNotFound(
        characteristicUUID: characteristic.uuid
      )
    }
    setNotifyValue(value, for: cb)
  }

  /// Typed `Characteristic` version with completion handler.
  public func setNotifyValue(
    _ value: Bool,
    for characteristic: Characteristic,
    completionHandler: @escaping (Result<Bool, Error>) -> Void
  ) throws {
    guard let cb = knownCharacteristics[characteristic.uuid] else {
      throw PeripheralError.characteristicNotFound(
        characteristicUUID: characteristic.uuid
      )
    }
    setNotifyValue(value, for: cb, completionHandler: completionHandler)
  }

  /// Write data to a typed `Characteristic` synchronously.
  ///
  /// - Parameters:
  ///   - data: The `Data` to write.
  ///   - characteristic: The typed `Characteristic`.
  ///   - type: The write type.
  /// - Throws: If characteristic not found.
  public func writeValue(
    _ data: Data,
    for characteristic: Characteristic,
    type: CBCharacteristicWriteType
  ) throws {
    guard let cb = knownCharacteristics[characteristic.uuid] else {
      throw PeripheralError.characteristicNotFound(
        characteristicUUID: characteristic.uuid
      )
    }
    writeValue(data, for: cb, type: type)
  }

  /// Read RSSI via callback.
  ///
  /// - Parameter completionHandler: Called with `.success(RSSI)` or `.failure(error)`.
  public func readRSSI(
    completionHandler: @escaping (Result<NSNumber, Error>) -> Void
  ) {
    eventQueue.async { [self] in
      eventSubscriptions.queue { event, done in
        guard case .readRSSI(let RSSI, let err) = event else { return }
        defer { done() }
        if let e = err { completionHandler(.failure(e)) } else { completionHandler(.success(RSSI)) }
      }
      readRSSI()
    }
  }

  #if !os(macOS)
    /// Open an L2CAP channel via callback (iOS/tvOS/watchOS only).
    ///
    /// - Parameters:
    ///   - PSM: The Protocol/Service Multiplexer.
    ///   - completionHandler: Called with `.success(channel)` or `.failure(error)`.
    @available(iOS 11.0, tvOS 11.0, watchOS 4.0, *)
    func openL2CAPChannel(
      _ PSM: CBL2CAPPSM,
      completionHandler: @escaping (Result<CBL2CAPChannel, Error>) -> Void
    ) {
      eventQueue.async { [self] in
        eventSubscriptions.queue { event, done in
          guard case .didOpenL2CAPChannel(let channel, let err) = event else { return }
          defer { done() }
          if let e = err {
            completionHandler(.failure(e))
          } else if let c = channel {
            completionHandler(.success(c))
          } else {
            completionHandler(.failure(PeripheralError.unknown))
          }
        }
        openL2CAPChannel(PSM)
      }
    }
  #endif
}
