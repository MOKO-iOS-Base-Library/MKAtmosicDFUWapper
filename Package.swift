// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MKAtmosicDFUWapper",
    platforms: [
        .iOS(.v18)
    ],
    products: [
        .library(
            name: "MKAtmosicDFUWapper",
            targets: ["MKAtmosicDFUWapper"]
        )
    ],
    dependencies: [
    ],
    targets: [
        .binaryTarget(
            name: "blelib",
            path: "MKAtmosicDFUWapper/Frameworks/blelib.xcframework"
        ),
        .target(
            name: "MKAtmosicDFUWapper",
            dependencies: [
                "blelib",
            ],
            path: "MKAtmosicDFUWapper/Classes",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        )
    ]
)
