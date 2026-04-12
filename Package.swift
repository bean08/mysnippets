// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "MySnippets",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .executable(name: "MySnippets", targets: ["MySnippets"])
  ],
  targets: [
    .executableTarget(
      name: "MySnippets",
      path: "Sources/HieraSnipApp"
    )
  ]
)
