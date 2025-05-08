// swift-tools-version: 5.5

import PackageDescription

let package = Package(
  name: "BlueKit",
  platforms: [
    .iOS(.v14),
    .macOS(.v10_15),
    .tvOS(.v15),
    .watchOS(.v7),
  ],
  products: [
    .library(name: "BlueKit", targets: ["BlueKit"])
  ],
  dependencies: [
    .package(
      url: "https://github.com/NordicSemiconductor/IOS-CoreBluetooth-Mock.git", "0.17.0"..<"0.18.0")
  ],
  targets: [
    .target(name: "BlueKit"),
    .target(
      name: "BlueKitMock",
      dependencies: [.product(name: "CoreBluetoothMock", package: "IOS-CoreBluetooth-Mock")],
      exclude: ["BlueKit/CentralManager/CBCentralManagerFactory.swift"]),
    .testTarget(
      name: "BlueKitTests",
      dependencies: ["BlueKitMock"]),
  ]
)
