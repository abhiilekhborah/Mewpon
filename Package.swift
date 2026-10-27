// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Mewpon", platforms: [.macOS(.v14)],
    products: [.executable(name: "Mewpon", targets: ["MewponDesktop"]),
               .executable(name: "MewponLauncher", targets: ["MewponLauncher"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "MewponShortcut", linkerSettings: [.linkedFramework("Carbon")]),
        .executableTarget(name: "MewponLauncher", dependencies: ["MewponShortcut"]),
        .target(name: "MewponCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "MewponDesktop", dependencies: ["MewponCore", "MewponShortcut"],
                          resources: [.copy("Resources/ExistingMewponAvatar")],
                          linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("IOKit")]),
        .testTarget(name: "MewponCoreTests", dependencies: ["MewponCore", "MewponDesktop", "MewponShortcut"])
    ]
)
