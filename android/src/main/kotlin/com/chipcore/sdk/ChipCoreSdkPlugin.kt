package com.chipcore.sdk

import com.chipcore.sdk.flutter.ChipCoreBlockchainApi
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding

/**
 * Flutter plugin entry point for chipcore_sdk.
 *
 * card_coin 在 pubspec.yaml 添加 chipcore_sdk 依赖后，Flutter 工具链
 * 通过 pubspec.yaml 的 flutter.plugin.platforms.android.pluginClass 声明
 * 自动发现并实例化此类，完成 Pigeon 通道注册。
 */
class ChipCoreSdkPlugin : FlutterPlugin, ActivityAware {

    private var binding: FlutterPlugin.FlutterPluginBinding? = null

    // ── FlutterPlugin ──────────────────────────────────────────────────────

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        binding = flutterPluginBinding
    }

    override fun onDetachedFromEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        binding = null
    }

    // ── ActivityAware ──────────────────────────────────────────────────────
    // ChipCoreBlockchainApi 需要 Activity 引用来管理 NFC 会话。

    override fun onAttachedToActivity(activityBinding: ActivityPluginBinding) {
        val messenger = binding?.binaryMessenger ?: return
        ChipCoreBlockchainApi.register(messenger, activityBinding.activity)
    }

    override fun onReattachedToActivityForConfigChanges(activityBinding: ActivityPluginBinding) {
        onAttachedToActivity(activityBinding)
    }

    override fun onDetachedFromActivity() { /* nothing */ }

    override fun onDetachedFromActivityForConfigChanges() { /* nothing */ }
}
