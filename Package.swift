// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RecordTree",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "RecordTree",
            path: "Sources/RecordTree",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
