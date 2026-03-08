// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "mysnippets",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .executable(name: "mysnippets", targets: ["mysnippets"])
  ],
  targets: [
    .executableTarget(
      name: "mysnippets",
      path: "Sources/HieraSnipApp"
    )
  ]
)
