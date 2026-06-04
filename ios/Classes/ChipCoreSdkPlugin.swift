import Flutter
import UIKit

/**
 * iOS Flutter plugin entry point for chipcore_sdk.
 *
 * card_coin 在 pubspec.yaml 添加 chipcore_sdk 依赖后，Flutter 工具链
 * 通过 pubspec.yaml 的 flutter.plugin.platforms.ios.pluginClass 声明
 * 自动发现并调用此类的 register 方法。
 */
public class ChipCoreSdkPlugin: NSObject, FlutterPlugin {

    public static func register(with registrar: FlutterPluginRegistrar) {
        // 将 Pigeon 通道注册到 Flutter engine。
        // Runner/ChipCoreBlockchainApi.swift 中的 ChipCoreBlockchainApi.register
        // 完成实际的 BlockchainApiSetup.setUp 调用。
        ChipCoreBlockchainApi.register(binaryMessenger: registrar.messenger())
    }
}
