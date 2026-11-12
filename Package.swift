// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "MicroscopeCore", platforms: [.macOS(.v14), .iOS(.v17)], products: [.library(name: "MicroscopeCore", targets: ["MicroscopeCore"]), .library(name: "CompanionLink", targets: ["CompanionLink"])], targets: [.target(name: "MicroscopeCore"), .target(name: "CompanionLink"), .testTarget(name: "MicroscopeCoreTests", dependencies: ["MicroscopeCore"]), .testTarget(name: "CompanionLinkTests", dependencies: ["CompanionLink"])])
