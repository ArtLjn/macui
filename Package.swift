// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacWallpaperWall",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "WallpaperWall"),
        .testTarget(name: "WallpaperWallTests", dependencies: ["WallpaperWall"])
    ]
)
