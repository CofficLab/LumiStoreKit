// swift-tools-version: 6.0
import PackageDescription

// LumiStoreKit：StoreKit 2 能力的业务无关工具层。
//
// 定位（对齐 Lumi 的 Kit 分层）：Kit 只提供**机制**工具，不含业务语义。
// - 本包不认识「档位」（Pro / Ultimate 是各 App 的产品语义，属 Provider 层）。
// - 本包不认识任何 App 的商品 ID 清单（由各 App 通过 StoreKitConfiguration 注入）。
// - 本包不依赖任何 Provider 包：依赖方向是 Provider → Kit，而非反向。
//
// 契约层在 LumiProviders（ProviderStore），各 App 的商店功能在各自的 PluginStore。
let package = Package(
    name: "LumiStoreKit",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "KitStoreKit", targets: ["KitStoreKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/CofficLab/LumiLogging.git", from: "1.0.1"),
    ],
    targets: [
        .target(
            name: "KitStoreKit",
            dependencies: [
                .product(name: "LumiLoggingKit", package: "LumiLogging"),
            ],
            path: "Sources/KitStoreKit"
        ),
        .testTarget(
            name: "KitStoreKitTests",
            dependencies: ["KitStoreKit"],
            path: "Tests/KitStoreKitTests"
        ),
    ]
)
