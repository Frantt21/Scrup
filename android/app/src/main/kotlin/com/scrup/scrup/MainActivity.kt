package com.scrup.scrup

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "com.scrup.music.toolchain"
        private const val TAG = "Scrup"

        init {
            System.loadLibrary("scrup_python")
        }

        // ABI del CPython embebido según el dispositivo. La toolchain de
        // python.org usa `aarch64` (arm64-v8a) y `x86_64`; elegimos el que
        // coincide con el ABI nativo del proceso para que sus módulos .so
        // (lib-dynload: zlib, _ssl, ...) se carguen correctamente.
        fun toolchainAbi(): String {
            val abi = Build.SUPPORTED_ABIS.firstOrNull() ?: ""
            return when {
                abi.startsWith("arm64") || abi.startsWith("aarch64") -> "aarch64"
                abi.startsWith("x86_64") || abi.startsWith("x86") -> "x86_64"
                else -> "aarch64"
            }
        }
    }

    // Métodos nativos del driver JNI (libscrup_python.so, empaquetado como
    // jniLibs del APK -> apk_data_file, ejecutable por untrusted_app, a
    // diferencia de un binario suelto en app_data_file bloqueado por SELinux).
    private external fun pythonConfigure(home: String, pythonPath: String)
    private external fun pythonHello(): String
    private external fun pythonRunYtDlp(scriptPath: String, args: Array<String>, logPath: String): Int
    private external fun pythonCancel()

    // TODO TODOS los usos de Python corren en ESTE hilo único. CPython asocia
    // el GIL al hilo que inicializó el intérprete; usar Python desde otros
    // hilos sería incorrecto/concurrente, así que serializamos todo aquí.
    private val pythonExecutor =
        Executors.newSingleThreadExecutor { r -> Thread(r, "scrup-python").apply { isDaemon = true } }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Expone los assets nativos de la toolchain CPython/yt-dlp y el
        // ejecutor yt-dlp embebido (via libpython) a Dart.
        // La copia de assets se hace en Dart POR LOTES (≤12 archivos) para no
        // superar el límite de ~1MB del Binder por transacción.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getAbi" -> result.success(toolchainAbi())
                    "pythonConfigure" -> {
                        val home = call.argument<String>("home")
                        val pythonPath = call.argument<String>("pythonPath")
                        if (home == null || pythonPath == null) {
                            result.error("badArgs", "home and pythonPath required", null)
                            return@setMethodCallHandler
                        }
                        pythonExecutor.execute {
                            try {
                                pythonConfigure(home, pythonPath)
                                result.success(null)
                            } catch (e: Throwable) {
                                result.error("python", e.toString(), Log.getStackTraceString(e))
                            }
                        }
                    }
                    "pythonHello" -> {
                        pythonExecutor.execute {
                            try {
                                val msg = pythonHello()
                                result.success(msg)
                            } catch (e: Throwable) {
                                result.error("python", e.toString(), Log.getStackTraceString(e))
                            }
                        }
                    }
                    "ytDlpRun" -> {
                        val args = call.argument<List<String>>("args") ?: emptyList()
                        val logPath = call.argument<String>("logPath")
                        pythonExecutor.execute {
                            try {
                                val files = filesDir.absolutePath
                                val abi = toolchainAbi()
                                val home = "$files/toolchain/$abi"
                                pythonConfigure(home, "$home/lib/python3.14")
                                val ytdlp = "$home/yt-dlp"
                                val lp = logPath ?: "$home/tmp/ytdlp_run.log"

                                // Wrapper: fixes sys.argv for yt-dlp then runs it.
                                // stdout/stderr redirect and SSL_CERT_DIR are handled
                                // by the C driver (scrup_python_jni.c).
                                val wrapper = java.io.File(home, "_run_wrapper.py")
                                wrapper.writeText(
                                    "import sys, runpy\n" +
                                    "script = sys.argv[1]\n" +
                                    "sys.argv = [script] + sys.argv[2:]\n" +
                                    "try:\n" +
                                    "  runpy.run_path(script, run_name='__main__')\n" +
                                    "except SystemExit:\n" +
                                    "  pass\n"
                                )

                                // Call wrapper: _run_wrapper.py <ytdlp> [args...]
                                val wrapperArgs = arrayOf(ytdlp) + args.toTypedArray()
                                val rc = pythonRunYtDlp(wrapper.absolutePath, wrapperArgs, lp)
                                val out = try {
                                    java.io.File(lp).readText()
                                } catch (e: Exception) { "" }
                                result.success(hashMapOf("exitCode" to rc, "output" to out))
                            } catch (e: Throwable) {
                                result.error("python", e.toString(), Log.getStackTraceString(e))
                            }
                        }
                    }
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
                    "ytDlpCancel" -> {
                        // PyErr_SetInterrupt desde otro hilo: la ejecución en
                        // curso (hilo python) recibirá KeyboardInterrupt y
                        // devolverá exit code != 0.
                        try {
                            pythonCancel()
                            result.success(null)
                        } catch (e: Throwable) {
                            result.error("python", e.toString(), Log.getStackTraceString(e))
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // Nota: la inicialización de Python es LAZY. Ocurre la primera vez que
        // un ytDlpRun llega al driver (py_init), ya DESPUÉS de que Dart haya
        // extraído la toolchain del ABI correcto (ensureAndroidToolchain), de
        // modo que el home/pythonpath existen cuando Py_InitializeFromConfig
        // corre. Por eso aquí no lanzamos un hello de inicio que fallaría
        // antes de la extracción.
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
