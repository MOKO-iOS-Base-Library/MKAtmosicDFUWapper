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
        // blelib.xcframework 的 swiftinterface 声明了 import SwiftCBOR / SwiftProtobuf，
        // 所以编译期必须能解析这两个模块。虽然 blelib 已静态链接了它们的二进制，
        // 但接口元数据仍依赖这两个 package。
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
