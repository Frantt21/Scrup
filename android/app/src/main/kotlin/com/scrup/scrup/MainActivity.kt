package com.scrup.scrup

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "com.scrup.music.toolchain"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Expone los assets nativos de la toolchain CPython/yt-dlp
        // (android/app/src/main/assets/toolchain/) a Dart. La copia se hace en
        // Dart POR LOTES (≤12 archivos) para no superar el límite de ~1MB del
        // Binder por transacción (un solo invoke de los ~42MB crashearía).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "readMany" -> {
                        val paths = call.argument<List<String>>("paths")
                        if (paths == null) {
                            result.error("badArgs", "paths required", null)
                            return@setMethodCallHandler
                        }
                        val out = HashMap<String, ByteArray>()
                        for (p0 in paths) {
                            try {
                                assets.open("toolchain/$p0").use { out[p0] = it.readBytes() }
                            } catch (_: Exception) {
                                // Los archivos ausentes se omiten; Dart los
                                // detecta como fallo del lote.
                            }
                        }
                        result.success(out)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onResume() {
        super.onResume()
        requestNotificationPermission()
    }

    // El permiso de notificación (API 33+) es necesario para que el usuario
    // vea la notificación de MediaSession durante la reproducción en 2º plano.
    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < 33) return
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
    }
}