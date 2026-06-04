package com.chipbase.chipcore_sdk

import com.chipcore.sdk.flutter.ChipCoreBlockchainApi
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)
		ChipCoreBlockchainApi.register(flutterEngine.dartExecutor.binaryMessenger, this)
	}
}
