// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "cel-swift",
  platforms: [.macOS(.v13), .iOS(.v16)],
  products: [
    .library(name: "CEL", targets: ["CEL"]),
    .library(name: "CELPolicy", targets: ["CELPolicy"]),
    .library(name: "CELTest", targets: ["CELTest"]),
  ],
  dependencies: [
    // 1.38 requires Swift 6.1; stay on 1.37.x while the floor is 6.0.
    .package(url: "https://github.com/apple/swift-protobuf.git", .upToNextMinor(from: "1.37.0")),
    .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
  ],
  targets: [
    .target(
      name: "CEL",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    // Generated from third_party/cel-spec by tools/gen-protos.sh. Not a product.
    .target(
      name: "CELSpecProtos",
      dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .target(
      name: "CELPolicy",
      dependencies: ["CEL", .product(name: "Yams", package: "Yams")],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .target(
      name: "CELTest",
      dependencies: ["CEL", "CELPolicy"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "CELTests",
      dependencies: ["CEL"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "CELConformanceTests",
      dependencies: [
        "CEL",
        "CELSpecProtos",
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
      ],
      exclude: ["skip.txt", "passing.txt"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "CELPolicyTests",
      dependencies: ["CEL", "CELPolicy"],
      exclude: ["Goldens"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "CELTestTests",
      dependencies: ["CELTest", "CELPolicy"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .target(
      name: "CELRegex",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "CELRegexTests",
      dependencies: ["CELRegex"],
      resources: [.copy("Resources")],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
  ]
)
