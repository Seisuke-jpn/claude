// swift-tools-version: 5.9

// Swift Playgrounds (iPad) / Xcode で開けるアプリプロジェクトです。
// Swift Playgrounds でアプリ設定を変更すると、このファイルは自動で書き換えられます。

import PackageDescription
import AppleProductTypes

let package = Package(
    name: "CoachBoard",
    platforms: [
        .iOS("17.0")
    ],
    products: [
        .iOSApplication(
            name: "CoachBoard",
            targets: ["AppModule"],
            bundleIdentifier: "com.example.coachboard",
            displayVersion: "0.1",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .pencil),
            accentColor: .presetColor(.red),
            supportedDeviceFamilies: [
                .pad
            ],
            supportedInterfaceOrientations: [
                .landscapeRight,
                .landscapeLeft,
                .portrait,
                .portraitUpsideDown
            ],
            capabilities: [
                .microphone(purposeString: "録画中に解説の声を録音するためにマイクを使用します。"),
                .photoLibraryAdd(purposeString: "録画した動画を写真ライブラリに保存します。")
            ]
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "."
        )
    ]
)
