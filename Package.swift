// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LittleRoute",
    platforms: [.iOS("18.1")],
    products: [
        // xtool expects exactly one library product: the app itself
        .library(name: "LittleRoute", targets: ["LittleRoute"]),
    ],
    targets: [
        .target(
            name: "LittleRoute",
            path: "LittleRoute",
            exclude: ["Info.plist", "LittleRoute.entitlements"]
        ),
    ]
)
