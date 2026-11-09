// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "BrewPeek",
  platforms: [.macOS(.v12)],
  products: [
    .executable(name: "BrewPeek", targets: ["BrewPeek"]),
    .executable(name: "BrewPeekAskpass", targets: ["BrewPeekAskpass"]),
  ],
  targets: [
    .executableTarget(
      name: "BrewPeek",
      path: "BrewPeek",
      exclude: ["Askpass", "Resources", "Web"],
      swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))]
    ),
    .testTarget(
      name: "CoreRegressionTests",
      dependencies: ["BrewPeek"],
      path: "Tests/CoreRegressionTests",
      resources: [.copy("Fixtures")]
    ),
    .testTarget(
      name: "SecurityRegressionTests",
      dependencies: ["BrewPeek"],
      path: "Tests/SecurityRegressionTests",
      resources: [.copy("Fixtures")]
    ),
    .executableTarget(
      name: "BrewPeekAskpass",
      path: "BrewPeek/Askpass",
      swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))]
    ),
  ],
  swiftLanguageVersions: [.v5]
)
