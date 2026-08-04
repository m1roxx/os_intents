// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// The macOS half of os_intents_ios. Same sources as the iOS half — `Sources/`
// is a symlink into `ios/` rather than a copy, because the two builds compile
// the *same* four files and a copy would be two files to keep in step. What
// differs between the platforms is inside them, under `#if os(macOS)`, and
// amounts to three things: the framework's name, `messenger` being a property
// rather than a method, and `FlutterEngine` having no `libraryURI` parameter.
//
// 10.15 rather than macOS 13: nothing here names an App Intents type. That
// floor belongs to the generated code, which carries `@available` for it, and
// imposing it on the plugin would cost it to every app that only wants the
// runtime.
let package = Package(
    name: "os_intents_ios",
    platforms: [
        .macOS("10.15")
    ],
    products: [
        .library(name: "os-intents-ios", targets: ["os_intents_ios"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "os_intents_ios",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ]
        )
    ]
)
