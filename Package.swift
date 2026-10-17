// swift-tools-version: 6.4

import PackageDescription

let settings: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .strictMemorySafety(),
  .defaultIsolation(.none),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("ImmutableWeakCaptures"),
  .enableUpcomingFeature("InternalImportsByDefault"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
  name: "swift-lifetime",
  platforms: [.macOS(.v27), .iOS(.v27), .tvOS(.v27), .watchOS(.v27)],
  products: [.library(name: "Lifetime", targets: ["Lifetime"])],
  targets: [
    .target(name: "Lifetime", swiftSettings: settings),
    .testTarget(name: "LifetimeTests", dependencies: ["Lifetime"], swiftSettings: settings),
  ],
  swiftLanguageModes: [.v6]
)
