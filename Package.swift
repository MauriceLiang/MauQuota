// swift-tools-version: 5.9
import PackageDescription

var packageProducts: [Product] = [
    .library(name: "MauQuotaCore", targets: ["MauQuotaCore"])
]
var packageTargets: [Target] = [
    .target(name: "MauQuotaCore"),
    .testTarget(name: "MauQuotaCoreTests", dependencies: ["MauQuotaCore"])
]

#if os(macOS)
packageProducts.append(.executable(name: "MauQuota", targets: ["MauQuota"]))
packageTargets.append(.executableTarget(name: "MauQuota", dependencies: ["MauQuotaCore"]))
#endif

let package = Package(
    name: "MauQuota",
    platforms: [.macOS(.v13)],
    products: packageProducts,
    targets: packageTargets
)
