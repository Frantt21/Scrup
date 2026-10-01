package com.scrup.scrup

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

/**
 * Guarda imágenes PNG en la galería del dispositivo vía MediaStore.
 *
 * API 29+ (Android 10+): inserción RELATIVE_PATH en Pictures/Scrup — no
 * requiere permisos de almacenamiento (scoped storage).
 * API < 29: escritura en el directorio público Pictures/Scrup (permiso
 * WRITE_EXTERNAL_STORAGE declarado en el manifest para maxSdkVersion 28).
 */
class ImageSaverHandler(private val context: Context) {

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "savePng" -> {
                val bytes = call.argument<ByteArray>("bytes")
                val displayName = call.argument<String>("displayName")
                if (bytes == null || displayName.isNullOrBlank()) {
                    result.error("bad-args", "bytes/displayName requeridos", null)
                    return
                }
                try {
                    val ok = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        savePngMediaStore(bytes, displayName) != null
                    } else {
                        savePngLegacy(bytes, displayName)
                    }
                    result.success(ok)
                } catch (e: Exception) {
                    result.error("save-failed", e.message, null)
                }
            }
            else -> result.notImplemented()
        }
    }

    /** API 29+: MediaStore con IS_PENDING y RELATIVE_PATH Pictures/Scrup. */
    private fun savePngMediaStore(bytes: ByteArray, displayName: String): Uri? {
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, displayName)
            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
            put(
                MediaStore.Images.Media.RELATIVE_PATH,
                "${Environment.DIRECTORY_PICTURES}/Scrup",
            )
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val resolver = context.contentResolver
        val uri = resolver.insert(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            values,
        ) ?: return null
        try {
            resolver.openOutputStream(uri)?.use { out ->
                out.write(bytes)
                out.flush()
            } ?: throw IllegalStateException("no output stream")
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
        values.clear()
        values.put(MediaStore.Images.Media.IS_PENDING, 0)
        resolver.update(uri, values, null, null)
        return uri
    }

    /** API < 29: archivo directo en Pictures/Scrup. */
    private fun savePngLegacy(bytes: ByteArray, displayName: String): Boolean {
        val dir = File(
            Environment.getExternalStoragePublicDirectory(
                Environment.DIRECTORY_PICTURES,
            ),
            "Scrup",
        )
        if (!dir.exists()) dir.mkdirs()
        val file = File(dir, displayName)
        FileOutputStream(file).use { out ->
            out.write(bytes)
            out.flush()
        }
        return file.exists() && file.length() > 0L
    }
}
