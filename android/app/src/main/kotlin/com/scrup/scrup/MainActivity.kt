package com.scrup.scrup

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "com.scrup.music.toolchain"
        private const val TAG = "Scrup"
    }

    private lateinit var ytDlpHandler: YtDlpHandler

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        ytDlpHandler = YtDlpHandler(this)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getAbi" -> {
                        val abi = Build.SUPPORTED_ABIS.firstOrNull() ?: ""
                        result.success(abi)
                    }
                    // Delegate yt-dlp calls to YtDlpHandler
                    "ytdlpInit", "ytdlpRun", "ytdlpCancel", "ytdlpVersion" -> {
                        ytDlpHandler.handleMethodCall(call, result)
                    }
                    // Legacy methods - delegate to YtDlpHandler for compatibility
                    "pythonHello" -> {
                        ytDlpHandler.init()
                        result.success("ok (using youtubedl-android)")
                    }
                    "ytDlpRun" -> {
                        // Legacy call - convert args and delegate
                        val args = call.argument<List<String>>("args") ?: emptyList()
                        val logPath = call.argument<String>("logPath")
                        // Create a new MethodCall with the right method name
                        val newCall = MethodCall("ytdlpRun", mapOf(
                            "args" to args,
                            "logPath" to logPath
                        ))
                        ytDlpHandler.handleMethodCall(newCall, result)
                    }
                    "ytDlpCancel" -> {
                        ytDlpHandler.handleMethodCall(MethodCall("ytdlpCancel", null), result)
                    }
                    "readMany" -> {
                        // Assets reading - return empty for now since youtubedl-android
                        // bundles its own Python/FFmpeg
                        result.success(emptyMap<String, ByteArray>())
                    }
                    else -> result.notImplemented()
                }
            }

        // Initialize youtubedl-android on startup
        Thread {
            try {
                ytDlpHandler.init()
            } catch (e: Exception) {
                Log.e(TAG, "Failed to init youtubedl-android", e)
            }
        }.start()
    }

    override fun onResume() {
        super.onResume()
        requestNotificationPermission()
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < 33) return
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED) return
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
    }
}
