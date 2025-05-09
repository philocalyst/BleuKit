# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [2.0.0] – 2025-05-08

### Changed

-   **BREAKING:** Renamed library from `SwiftBluetooth` to `BleuKit`. This affects imports (`import BleuKit`), package dependencies (`github.com/exPHAT/BleuKit.git`), target names (`BleuKit`, `BleuKitMock`, `BleuKitTests`), and potentially typealiases if used for migration.
-   Replaced internal dispatch queues with `NSLock` for improved thread safety in subscription queues.
-   Replaced fatal errors with throwing `PeripheralError` when characteristics or descriptors are not found.
-   Updated several methods to use `Result` or `throws` for error handling (e.g., `waitUntilReady`, `connect`, discovery methods, read/write methods).
-   Used standard `CancellationError` for task cancellation instead of a custom error type.
-   Peripheral references are now retained for the lifetime of the `CentralManager` to prevent issues when accessing disconnected peripherals.
-   Scanning methods (`scanForPeripherals`) now return `AsyncStream<PeripheralScanResult>` or provide `PeripheralScanResult` in callbacks, exposing `advertisementData` and `rssi`.
-   `Peripheral.DiscoveryInfo.RSSI` renamed to `rssi` for consistency.
-   `Peripheral.cbPeripheral` is now public for direct access if needed.
-   Improved handling of `setNotifyValue(false, ...)` to correctly end associated notification streams.
-   Updated `Package.swift` format and dependency specification.
-   Various internal code reorganizations and variable name changes for clarity.

### Added

-   Added `timeout` parameters to `connect` and `scanForPeripherals` methods.
-   Added async support for `setNotifyValue` via `peripheral.setNotifyValue(_:for:) async throws`.
-   Added `Sendable` conformance for `CBUUID` using `@retroactive` for improved concurrency safety.
-   Added localized error descriptions for `CentralError` and `PeripheralError`.
-   Added extensive documentation comments throughout the library.
-   Added testing infrastructure using `CoreBluetoothMock`.

### Removed

-   Removed internal `DispatchQueue` usage from subscription queues (replaced by locks).

### Fixed

-   Fixed potential race conditions in `CentralManager` event handling and delegate callbacks.
-   Ensured delegate methods are consistently called on the main thread.
-   Fixed potential crash when discovering characteristics with specific UUIDs.
-   Resolved method signature collision for `scanForPeripherals`.
-   Fixed various typos in internal method names (e.g., `recieve` -> `receive`).
-   Ensured scanning stops correctly when `stopScan()` is called or the scanning task/stream is cancelled.
-   Improved Swift 5.6 compatibility.
-   Corrected code formatting and style issues.
-   Fixed build/tooling issues related to symlinks and directory renames for the mock target.

## [1.0.0] - 2024-04-16

### Added

-   Initial release. (NOT BY ME!!) Forked here.

[Unreleased]: https://github.com/exPHAT/BleuKit/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/exPHAT/BleuKit/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/exPHAT/BleuKit/releases/tag/v1.0.0

