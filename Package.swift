// swift-tools-version: 5.5

import PackageDescription

let package = Package(
  name: "BleuKit",
  platforms: [
    .iOS(.v14),
    .macOS(.v10_15),
    .tvOS(.v15),
    .watchOS(.v7),
  ],
  products: [
    .library(name: "BleuKit", targets: ["BleuKit"])
  ],
  dependencies: [
    .package(
      url: "https://github.com/NordicSemiconductor/IOS-CoreBluetooth-Mock.git", "0.17.0"..<"0.18.0")
  ],
  targets: [
    .target(name: "BleuKit"),
    .target(
      name: "BleuKitMock",
      dependencies: [.product(name: "CoreBluetoothMock", package: "IOS-CoreBluetooth-Mock")],
      exclude: ["BleuKit/CentralManager/CBCentralManagerFactory.swift"]),
    .testTarget(
      name: "BleuKitTests",
      dependencies: ["BleuKitMock"]),
  ]
)
