package com.scrup.scrup

import android.content.Context
import android.util.Log
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Wraps youtubedl-android (com.yausername.youtubedl_android) to run yt-dlp
 * on Android. Handles init, search, download, and version check.
 */
class YtDlpHandler(private val context: Context) {
    companion object {
        private const val TAG = "YtDlpHandler"
    }

    private var initialized = false
    private var currentProcessId: String? = null

    fun init() {
        if (initialized) return
        try {
            YoutubeDL.getInstance().init(context)
            initialized = true
            Log.i(TAG, "youtubedl-android initialized OK")
        } catch (e: Exception) {
            Log.e(TAG, "Init failed: ${e.message}", e)
        }
    }

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ytdlpInit" -> {
                init()
                result.success(true)
            }
            "ytdlpRun" -> {
                val args = call.argument<List<String>>("args") ?: emptyList()
                val logPath = call.argument<String>("logPath")
                executeYtDlp(args, logPath, result)
            }
            "ytdlpCancel" -> {
                try {
                    val pid = currentProcessId
                    if (pid != null) {
                        YoutubeDL.getInstance().destroyProcessById(pid)
                        currentProcessId = null
                    }
                    result.success(true)
                } catch (e: Exception) {
                    Log.w(TAG, "Cancel failed: $e")
                    result.success(false)
                }
            }
            "ytdlpVersion" -> {
                CoroutineScope(Dispatchers.IO).launch {
                    try {
                        // Use getInfo with --version to get version string
                        val request = YoutubeDLRequest(listOf("--version"))
                        val response = YoutubeDL.getInstance().execute(request)
                        val version = response.out.trim()
                        withContext(Dispatchers.Main) {
                            result.success(version.ifEmpty { "unknown" })
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Version check failed", e)
                        withContext(Dispatchers.Main) {
                            result.error("version", e.toString(), null)
                        }
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Execute yt-dlp with the given args. The last arg is typically the URL.
     * youtubedl-android expects the URL as constructor arg and options via addOption.
     * We parse the args to extract the URL from the end and add the rest as options.
     */
    private fun executeYtDlp(
        args: List<String>,
        logPath: String?,
        result: MethodChannel.Result
    ) {
        if (!initialized) {
            result.error("notInitialized", "youtubedl-android not initialized", null)
            return
        }

        CoroutineScope(Dispatchers.IO).launch {
            try {
                Log.i(TAG, "Executing: ${args.joinToString(" ")}")

                // Pass all args as raw commands — Dart already builds the
                // correct argument list with URLs, flags, and values.
                val request = YoutubeDLRequest(emptyList())
                request.addCommands(args)

                val processId = "scrup_${System.currentTimeMillis()}"
                currentProcessId = processId

                val response = YoutubeDL.getInstance().execute(request, processId)
                currentProcessId = null

                Log.i(TAG, "yt-dlp exit=${response.exitCode} out=${response.out.take(200)}")

                // Write to log file
                if (logPath != null) {
                    try {
                        java.io.File(logPath).writeText(response.out)
                    } catch (e: Exception) {
                        Log.w(TAG, "Log write failed: $e")
                    }
                }

                withContext(Dispatchers.Main) {
                    val resultMap = hashMapOf<String, Any?>(
                        "exitCode" to response.exitCode,
                        "output" to response.out,
                        "error" to response.err
                    )
                    result.success(resultMap)
                }
            } catch (e: com.yausername.youtubedl_android.YoutubeDLException) {
                // Non-zero exit: library throws instead of returning the exit code.
                // Extract the error output and return it as a result map so Dart
                // can parse stderr like it does on desktop.
                currentProcessId = null
                val errMsg = e.message ?: "yt-dlp error"
                Log.e(TAG, "yt-dlp error: $errMsg")
                if (logPath != null) {
                    try { java.io.File(logPath).writeText(errMsg) } catch (_: Exception) {}
                }
                withContext(Dispatchers.Main) {
                    val resultMap = hashMapOf<String, Any?>(
                        "exitCode" to 1,
                        "output" to errMsg,
                        "error" to errMsg
                    )
                    result.success(resultMap)
                }
            } catch (e: Exception) {
                currentProcessId = null
                Log.e(TAG, "Execution failed: ${e.message}", e)
                withContext(Dispatchers.Main) {
                    result.error("execution", e.message ?: "Unknown error", e.stackTraceToString())
                }
            }
        }
    }
}
