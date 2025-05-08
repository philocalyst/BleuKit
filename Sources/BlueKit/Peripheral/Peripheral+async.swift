import CoreBluetooth
import Foundation

extension Peripheral {
  /// Asynchronously read the value of a CBCharacteristic.
  ///
  /// - Parameter characteristic: The CoreBluetooth characteristic.
  /// - Returns: The `Data` read.
  /// - Throws: An error if the read fails or the peripheral disconnects.
  @available(iOS 13, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
  public func readValue(for characteristic: CBCharacteristic) async throws -> Data {
    try await withCheckedThrowingContinuation { cont in
      self.readValue(for: characteristic) { result in
        cont.resume(with: result)
      }
    }
  }

  /// Asynchronously read the value of a typed `Characteristic`.
  ///
  /// - Parameter characteristic: The typed characteristic.
  /// - Returns: The `Data` read.
  /// - Throws: `PeripheralError.characteristicNotFound` if unmapped,
  ///           or other read errors.
  @available(iOS 13, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
  public func readValue(for characteristic: Characteristic) async throws -> Data {
    guard let cb = knownCharacteristics[characteristic.uuid] else {
      throw PeripheralError.characteristicNotFound(characteristicUUID: characteristic.uuid)
    }
    return try await readValue(for: cb)
  }

  /// Asynchronously read a descriptor’s value.
  ///
  /// - Parameter descriptor: The `CBDescriptor`.
  /// - Returns: The descriptor’s value.
  @available(iOS 13, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
  public func readValue(for descriptor: CBDescriptor) async throws -> Any? {
    try await withCheckedThrowingContinuation { cont in
      self.readValue(for: descriptor) { result in
        cont.resume(with: result)
      }
    }
  }

  /// Creates an AsyncStream of Data updates for a notifying characteristic.
  ///
  /// - Parameter characteristic: The characteristic to observe.
  /// - Returns: An `AsyncStream<Data>` yielding each value update.
  @available(iOS 13, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
  public func readValues(for characteristic: CBCharacteristic) -> AsyncStream<Data> {
    .init { cont in
      var readTask: AsyncSubscription<Result<Data, Error>>?
      var stateTask: AsyncSubscription<PeripheralEvent>?
      let cancelAll = {
        readTask?.cancel()
        stateTask?.cancel()
      }

      readTask = responseMap.queue(key: characteristic.uuid) { result, done in
        switch result {
        case .success(let data):
          cont.yield(data)
        case .failure:
          cont.finish()
          stateTask?.cancel()
          done()
        }
      } completion: { [weak self] in
        guard let self = self else { return }
        let keepNotifying = self.notifyingState.removeInternal(forKey: characteristic.uuid)
        self.cbPeripheral.setNotifyValue(keepNotifying, for: characteristic)
      }

      stateTask = eventSubscriptions.queue { event, done in
        if case .didDisconnect = event {
          cont.finish()
          readTask?.cancel()
          done()
          return
        }
        guard case .updateNotificationState(let ch, let err) = event,
          ch.uuid == characteristic.uuid,
          !ch.isNotifying || err != nil
        else { return }
        cont.finish()
        readTask?.cancel()
        done()
      }

      cont.onTermination = { _ in cancelAll() }
      notifyingState.addInternal(forKey: characteristic.uuid)
      cbPeripheral.setNotifyValue(true, for: characteristic)
    }
  }

  /// Same as above, but for typed `Characteristic`.
  @available(iOS 13, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
  public func readValues(for characteristic: Characteristic) throws -> AsyncStream<Data> {
    guard let cb = knownCharacteristics[characteristic.uuid] else {
      throw PeripheralError.characteristicNotFound(characteristicUUID: characteristic.uuid)
    }
    return readValues(for: cb)
  }

  /// Asynchronously write data to a characteristic with response.
  ///
  /// - Parameters:
  ///   - data: The `Data` to write.
  ///   - characteristic: The `CBCharacteristic`.
  ///   - type: Write type (`.withResponse` or `.withoutResponse`).
  /// - Throws: If the write fails.
  @available(iOS 13, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
  public func writeValue(
    _ data: Data,
    for characteristic: CBCharacteristic,
    type: CBCharacteristicWriteType
  ) async throws {
    try await withCheckedThrowingContinuation {
      (
        cont:
          CheckedContinuation<Void, Error>
      ) in
      self.writeValue(data, for: characteristic, type: type) { err in
        if let e = err { cont.resume(throwing: e) } else { cont.resume() }
      }
    }
  }

  /// Asynchronously write data to a descriptor.
  ///
  /// - Parameters:
  ///   - data: The `Data` to write.
  ///   - descriptor: The `CBDescriptor`.
  /// - Throws: If the write fails.
  @available(iOS 13, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
  public func writeValue(_ data: Data, for descriptor: CBDescriptor) async throws {
    try await withCheckedThrowingContinuation {
      (
        cont:
          CheckedContinuation<Void, Error>
      ) in
      self.writeValue(data, for: descriptor) { err in
        if let e = err { cont.resume(throwing: e) } else { cont.resume() }
      }
    }
  }

  /// Asynchronously write to a typed `Characteristic`.
  ///
  /// - Parameters:
  ///   - data: The `Data` to write.
  ///   - characteristic: The typed `Characteristic`.
  ///   - type: The write type.
  /// - Throws: If characteristic not found or write fails.
  @available(iOS 13, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
  public func writeValue(
    _ data: Data,
    for characteristic: Characteristic,
    type: CBCharacteristicWriteType
  ) async throws {
    guard let cb = knownCharacteristics[characteristic.uuid] else {
      throw PeripheralError.characteristicNotFound(characteristicUUID: characteristic.uuid)
    }
    try await writeValue(data, for: cb, type: type)
  }

  /// Asynchronously discover services on the peripheral.
  ///
  /// - Parameter serviceUUIDs: Array of `CBUUID` to discover, or `nil`.
  /// - Returns: An array of discovered `CBService`.
  /// - Throws: If the discover fails or disconnects.
  @available(iOS 13, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
  public func discoverServices(_ serviceUUIDs: [CBUUID]? = nil) async throws -> [CBService] {
    try await withCheckedThrowingContinuation { cont in
      self.discoverServices(serviceUUIDs) { result in cont.resume(with: result) }
    }
  }

  /// Asynchronously discover characteristics for a service.
  ///
  /// - Parameters:
  ///   - characteristicUUIDs: Array of `CBUUID` to discover, or `nil`.
  ///   - service: The service to inspect.
  /// - Returns: An array of discovered `CBCharacteristic`.
  /// - Throws: If the discover fails or disconnects.
  @available(iOS 13, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
  public func discoverCharacteristics(
    _ characteristicUUIDs: [CBUUID]? = nil,
    for service: CBService
  ) async throws -> [CBCharacteristic] {
    try await withCheckedThrowingContinuation { cont in
      self.discoverCharacteristics(characteristicUUIDs, for: service) {
        cont.resume(with: $0)
      }
    }
  }

  /// Asynchronously discover descriptors for a characteristic.
  ///
  /// - Parameter characteristic: The `CBCharacteristic`.
  /// - Returns: An array of discovered `CBDescriptor`.
  /// - Throws: If the discover fails or disconnects.
  @available(iOS 13, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
  public func discoverDescriptors(for characteristic: CBCharacteristic) async throws
    -> [CBDescriptor]
  {
    try await withCheckedThrowingContinuation { cont in
      self.discoverDescriptors(for: characteristic) { cont.resume(with: $0) }
    }
  }

  /// Asynchronously set notification state for a typed characteristic.
  ///
  /// - Parameters:
  ///   - value: `true` to enable, `false` to disable.
  ///   - characteristic: The `CBCharacteristic`.
  /// - Returns: The new `isNotifying` state.
  /// - Throws: If the request fails.
  @available(iOS 13, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
  @discardableResult
  public func setNotifyValue(
    _ value: Bool,
    for characteristic: CBCharacteristic
  ) async throws -> Bool {
    try await withCheckedThrowingContinuation { cont in
      self.setNotifyValue(value, for: characteristic) { result in
        cont.resume(with: result)
      }
    }
  }

  /// Asynchronously set notification state for a typed `Characteristic`.
  ///
  /// - Parameters:
  ///   - value: `true` to enable, `false` to disable.
  ///   - characteristic: The typed `Characteristic`.
  /// - Returns: The new notifying state.
  /// - Throws: If the characteristic is not found or the request fails.
  @available(iOS 13, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
  @discardableResult
  public func setNotifyValue(
    _ value: Bool,
    for characteristic: Characteristic
  ) async throws -> Bool {
    try await withCheckedThrowingContinuation { cont in
      do {
        try self.setNotifyValue(value, for: characteristic) { cont.resume(with: $0) }
      } catch {
        cont.resume(throwing: error)
      }
    }
  }

  /// Asynchronously read the RSSI of the peripheral.
  ///
  /// - Returns: The current RSSI as `NSNumber`.
  /// - Throws: If the read fails.
  @available(iOS 13, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
  public func readRSSI() async throws -> NSNumber {
    try await withCheckedThrowingContinuation { cont in
      self.readRSSI { cont.resume(with: $0) }
    }
  }

  #if !os(macOS)
    /// Asynchronously open an L2CAP channel (iOS/tvOS/watchOS only).
    ///
    /// - Parameter PSM: The Protocol/Service Multiplexer.
    /// - Returns: The opened `CBL2CAPChannel`.
    /// - Throws: If the open fails.
    @available(iOS 13.0, tvOS 13.0, watchOS 6.0, *)
    func openL2CAPChannel(_ PSM: CBL2CAPPSM) async throws -> CBL2CAPChannel {
      try await withCheckedThrowingContinuation { cont in
        self.openL2CAPChannel(PSM) { result in
          switch result {
          case .success(let chan): cont.resume(returning: chan)
          case .failure(let err): cont.resume(throwing: err)
          }
        }
      }
    }
  #endif
}
