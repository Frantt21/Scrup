package com.scrup.scrup

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Lanza el instalador de paquetes de Android para el APK descargado por el
 * servicio de actualizaciones.
 *
 * El APK vive en el directorio de caché privado de la app, así que para poder
 * pasárselo al instalador del sistema hay que exponerlo con un FileProvider
 * (`<authority>.fileprovider`, declarado en el manifest con `cache-path`).
 * A partir de Android 7 (API 24) compartir un `file://` lanzaría
 * FileUriExposedException, de ahí el uso de `content://` + permiso de lectura.
 *
 * Requiere el permiso REQUEST_INSTALL_PACKAGES y, en Android 8+, que el usuario
 * permita a Scrup "instalar apps desconocidas".
 */
class ApkInstallerHandler(private val context: Context) {

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "installApk" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrBlank()) {
                    result.error("bad-args", "path requerido", null)
                    return
                }
                try {
                    installApk(File(path))
                    result.success(true)
                } catch (e: Exception) {
                    result.error("install-failed", e.message, null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun installApk(file: File) {
        if (!file.exists()) {
            throw IllegalArgumentException("APK no encontrado: ${file.path}")
        }
        val authority = "${context.packageName}.fileprovider"
        val uri: Uri = FileProvider.getUriForFile(context, authority, file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
    }
}
