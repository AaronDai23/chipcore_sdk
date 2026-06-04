package com.chipbase.chipcore_sdk

import android.app.Activity
import com.chipcore.sdk.flutter.ChipCoreBlockchainApi
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding

/**
 * Flutter 插件入口。
 * card_coin 通过 pubspec.yaml 依赖 chipcore_sdk 时，Flutter 工具链会根据
 * AndroidManifest.xml 中的 flutter.plugin.class 元数据自动发现并调用此类。
 */
class ChipCoreSdkPlugin : FlutterPlugin, ActivityAware {

    private var flutterPluginBinding: FlutterPlugin.FlutterPluginBinding? = null
    private var activity: Activity? = null

    // ── FlutterPlugin ───────────────────────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        flutterPluginBinding = binding
        // Activity 尚未绑定，等 onAttachedToActivity 再注册
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        flutterPluginBinding = null
    }

    // ── ActivityAware ───────────────────────────────────────────────────────

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        val messenger = flutterPluginBinding?.binaryMessenger ?: return
        ChipCoreBlockchainApi.register(messenger, binding.activity)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity()
    }
}
