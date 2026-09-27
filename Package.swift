// swift-tools-version: 6.2

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
  platforms: [.macOS(.v15), .iOS(.v18), .tvOS(.v18), .watchOS(.v11)],
  products: [.library(name: "Lifetime", targets: ["Lifetime"])],
  targets: [
    .target(name: "Lifetime", swiftSettings: settings),
    .testTarget(name: "LifetimeTests", dependencies: ["Lifetime"], swiftSettings: settings),
  ],
  swiftLanguageModes: [.v6]
)
