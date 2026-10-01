// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "cel-swift",
  platforms: [.macOS(.v13), .iOS(.v16)],
  products: [
    .library(name: "CEL", targets: ["CEL"])
  ],
  targets: [
    .target(
      name: "CEL",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "CELTests",
      dependencies: ["CEL"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
  ]
)
