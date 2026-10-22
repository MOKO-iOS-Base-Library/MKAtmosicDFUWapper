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
        .package(url: "https://github.com/unrelentingtech/SwiftCBOR.git", from: "0.6.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.25.0"),
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
                .product(name: "SwiftCBOR", package: "SwiftCBOR"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "MKAtmosicDFUWapper/Classes",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        )
    ]
)
