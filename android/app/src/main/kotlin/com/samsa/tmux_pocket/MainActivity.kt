package com.samsa.tmux_pocket

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Hands the home-screen widget's "hostId" extra to Dart ("" = the host list). */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tmux_pocket/launch").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialHost" -> {
                        result.success(intent.getStringExtra(HOST_ID))
                        intent.removeExtra(HOST_ID) // once, not again on an activity restart
                    }
                    "refresh" -> {
                        HostsWidget.refresh(this@MainActivity)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.getStringExtra(HOST_ID)?.let { channel?.invokeMethod("launch", it) }
    }
}
