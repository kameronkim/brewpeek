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
    .executableTarget(
      name: "BrewPeekAskpass",
      path: "BrewPeek/Askpass",
      swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))]
    ),
  ],
  swiftLanguageVersions: [.v5]
)
