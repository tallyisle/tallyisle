package dev.tallyisle.rebuild

import android.app.Activity
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors

/**
 * Android native bridge for saving exported bytes via SAF
 * ([Intent.ACTION_CREATE_DOCUMENT]) and sharing exported files via
 * `FileProvider` + [Intent.ACTION_SEND].
 */
class FileBridge(private val activity: Activity) {
    private var channel: MethodChannel? = null
    private var pendingSave: PendingSaveRequest? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val ioExecutor = Executors.newSingleThreadExecutor()

    private class PendingSaveRequest(
        val bytes: ByteArray,
        val result: MethodChannel.Result,
    )

    fun attach(messenger: BinaryMessenger) {
        val methodChannel = MethodChannel(messenger, CHANNEL_NAME)
        methodChannel.setMethodCallHandler(::handleMethodCall)
        channel = methodChannel
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
        val stale = pendingSave
        pendingSave = null
        stale?.result?.error(ERROR_CANCELLED, "已取消保存", null)
    }

    fun shutdown() {
        detach()
        ioExecutor.shutdown()
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "saveBytes" -> handleSaveBytes(call, result)
            "shareBytes" -> handleShareBytes(call, result)
            else -> result.notImplemented()
        }
    }

    private fun handleSaveBytes(call: MethodCall, result: MethodChannel.Result) {
        val rawName = call.argument<String>("suggestedName")
        val bytes = call.argument<ByteArray>("bytes")
        if (bytes == null) {
            result.error(ERROR_INVALID_ARGS, "缺少待保存文件内容", null)
            return
        }
        val safeName = sanitizeFileName(rawName, fallback = "backup.tally")
        val mimeType = call.argument<String>("mimeType")
            ?.takeIf { it.isNotBlank() }
            ?: guessMimeType(safeName)

        pendingSave?.result?.error(ERROR_CANCELLED, "已取消上一次保存", null)
        pendingSave = PendingSaveRequest(bytes = bytes, result = result)

        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeType
            putExtra(Intent.EXTRA_TITLE, safeName)
        }
        try {
            activity.startActivityForResult(intent, REQUEST_CODE_SAVE_DOCUMENT)
        } catch (e: Exception) {
            pendingSave = null
            result.error(ERROR_UNAVAILABLE, e.message ?: "无法打开系统文件保存器", null)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE_SAVE_DOCUMENT) return false
        val pending = pendingSave ?: return true
        pendingSave = null

        val targetUri = data?.data
        if (resultCode != Activity.RESULT_OK || targetUri == null) {
            pending.result.error(ERROR_CANCELLED, "已取消保存", null)
            return true
        }

        val appContext = activity.applicationContext
        ioExecutor.execute {
            try {
                writeAllBytesToUri(appContext, targetUri, pending.bytes)
                mainHandler.post {
                    pending.result.success(null)
                }
            } catch (_: Exception) {
                mainHandler.post {
                    pending.result.error(ERROR_IO, "文件未完成保存", null)
                }
            }
        }
        return true
    }

    private fun handleShareBytes(call: MethodCall, result: MethodChannel.Result) {
        val rawName = call.argument<String>("fileName")
        val bytes = call.argument<ByteArray>("bytes")
        if (bytes == null) {
            result.error(ERROR_INVALID_ARGS, "缺少待分享文件内容", null)
            return
        }
        val safeName = sanitizeFileName(rawName, fallback = "backup.tally")
        val mimeType = call.argument<String>("mimeType")
            ?.takeIf { it.isNotBlank() }
            ?: guessMimeType(safeName)
        val subject = call.argument<String>("subject")?.takeIf { it.isNotBlank() }
        val appContext = activity.applicationContext

        ioExecutor.execute {
            try {
                val exportsDir = File(appContext.cacheDir, EXPORTS_SUBDIR)
                if (!exportsDir.exists() && !exportsDir.mkdirs()) {
                    throw IllegalStateException("Cannot create exports cache dir")
                }
                pruneOldExports(exportsDir)

                val targetFile = File(exportsDir, safeName)
                val tempFile = File(exportsDir, "$safeName.tmp")
                FileOutputStream(tempFile).use { out ->
                    out.write(bytes)
                    out.flush()
                    out.fd.sync()
                }
                if (targetFile.exists()) {
                    targetFile.delete()
                }
                if (!tempFile.renameTo(targetFile)) {
                    FileOutputStream(targetFile).use { out ->
                        out.write(bytes)
                        out.flush()
                        out.fd.sync()
                    }
                    tempFile.delete()
                }

                val contentUri = resolveFileProviderUri(appContext, targetFile, safeName)
                mainHandler.post {
                    try {
                        val sendIntent = Intent(Intent.ACTION_SEND).apply {
                            type = mimeType
                            putExtra(Intent.EXTRA_STREAM, contentUri)
                            if (subject != null) {
                                putExtra(Intent.EXTRA_SUBJECT, subject)
                            }
                            clipData = ClipData.newRawUri(safeName, contentUri)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        val chooser = Intent.createChooser(sendIntent, subject ?: safeName).apply {
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        activity.startActivity(chooser)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error(ERROR_UNAVAILABLE, e.message ?: "无法调起系统分享", null)
                    }
                }
            } catch (_: Exception) {
                mainHandler.post {
                    result.error(ERROR_IO, "准备分享文件失败", null)
                }
            }
        }
    }

    private fun writeAllBytesToUri(context: Context, uri: Uri, bytes: ByteArray) {
        val resolver = context.contentResolver
        val stream = try {
            resolver.openOutputStream(uri, "wt")
        } catch (_: Exception) {
            resolver.openOutputStream(uri)
        } ?: throw IllegalStateException("Null OutputStream from ContentResolver")

        stream.use { out ->
            out.write(bytes)
            out.flush()
        }
    }

    private fun resolveFileProviderUri(
        context: Context,
        exportFile: File,
        safeName: String,
    ): Uri {
        val authority = "${context.packageName}.fileprovider"
        return try {
            val providerClass = Class.forName("androidx.core.content.FileProvider")
            val getUriMethod = providerClass.getMethod(
                "getUriForFile",
                Context::class.java,
                String::class.java,
                File::class.java,
            )
            getUriMethod.invoke(null, context, authority, exportFile) as Uri
        } catch (_: Exception) {
            Uri.Builder()
                .scheme("content")
                .authority(authority)
                .appendPath(SHARED_EXPORTS_NAME)
                .appendPath(safeName)
                .build()
        }
    }

    private fun pruneOldExports(exportsDir: File) {
        val cutoff = System.currentTimeMillis() - EXPORT_CACHE_TTL_MS
        val children = exportsDir.listFiles() ?: return
        for (child in children) {
            if (child.isFile && child.lastModified() in 1 until cutoff) {
                child.delete()
            }
        }
    }

    companion object {
        const val CHANNEL_NAME = "dev.tallyisle/files"
        const val REQUEST_CODE_SAVE_DOCUMENT = 4035

        private const val EXPORTS_SUBDIR = "exports"
        private const val SHARED_EXPORTS_NAME = "shared_exports"
        private const val EXPORT_CACHE_TTL_MS = 24L * 60L * 60L * 1000L

        private const val ERROR_CANCELLED = "CANCELLED"
        private const val ERROR_INVALID_ARGS = "INVALID_ARGS"
        private const val ERROR_IO = "IO_ERROR"
        private const val ERROR_UNAVAILABLE = "UNAVAILABLE"

        fun sanitizeFileName(raw: String?, fallback: String): String {
            val trimmed = raw?.trim().orEmpty()
            if (trimmed.isEmpty()) return fallback
            val stripped = trimmed
                .replace('/', '_')
                .replace('\\', '_')
                .replace('\u0000', '_')
            if (stripped == "." || stripped == "..") return fallback
            return stripped
        }

        fun guessMimeType(fileName: String): String {
            val lower = fileName.lowercase()
            return when {
                lower.endsWith(".csv") -> "text/csv"
                lower.endsWith(".json") || lower.endsWith(".ya2i") -> "application/json"
                lower.endsWith(".zip") -> "application/zip"
                lower.endsWith(".tally") || lower.endsWith(".tallyzip") -> "application/octet-stream"
                else -> "application/octet-stream"
            }
        }
    }
}
