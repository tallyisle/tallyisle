package com.tallyisle.app

import android.app.Activity
import android.content.ClipData
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.Executors

/**
 * Android native bridge for saving exported bytes via SAF
 * ([Intent.ACTION_CREATE_DOCUMENT]), binding persistent external backup
 * folders via [Intent.ACTION_OPEN_DOCUMENT_TREE] + [DocumentsContract], and
 * sharing exported files via `FileProvider` + [Intent.ACTION_SEND].
 */
class FileBridge(private val activity: Activity) {
    private var channel: MethodChannel? = null
    private var pendingSave: PendingSaveRequest? = null
    private var pendingPickDir: MethodChannel.Result? = null
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
        val staleSave = pendingSave
        pendingSave = null
        staleSave?.result?.error(ERROR_CANCELLED, "已取消保存", null)
        val stalePickDir = pendingPickDir
        pendingPickDir = null
        stalePickDir?.error(ERROR_CANCELLED, "已取消选择备份目录", null)
    }

    fun shutdown() {
        detach()
        ioExecutor.shutdown()
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "saveBytes" -> handleSaveBytes(call, result)
            "shareBytes" -> handleShareBytes(call, result)
            "openExternalUrl" -> handleOpenExternalUrl(call, result)
            "pickBackupDirectory" -> handlePickBackupDirectory(result)
            "checkDirectoryAccessible" -> handleCheckDirectoryAccessible(call, result)
            "listDirectoryBackups" -> handleListDirectoryBackups(call, result)
            "writeDirectoryBackup" -> handleWriteDirectoryBackup(call, result)
            "readDirectoryBackup" -> handleReadDirectoryBackup(call, result)
            "deleteDirectoryBackup" -> handleDeleteDirectoryBackup(call, result)
            else -> result.notImplemented()
        }
    }

    private fun handleOpenExternalUrl(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")?.trim().orEmpty()
        if (!url.startsWith("https://", ignoreCase = true) &&
            !url.startsWith("http://", ignoreCase = true)
        ) {
            result.error(ERROR_INVALID_ARGS, "仅支持打开 HTTP/HTTPS 网页链接", null)
            return
        }
        try {
            val uri = Uri.parse(url)
            if (uri.host.isNullOrBlank()) {
                result.error(ERROR_INVALID_ARGS, "仅支持打开 HTTP/HTTPS 网页链接", null)
                return
            }
            val intent = Intent(Intent.ACTION_VIEW, uri).apply {
                addCategory(Intent.CATEGORY_BROWSABLE)
            }
            activity.startActivity(intent)
            result.success(null)
        } catch (e: Exception) {
            result.error(ERROR_UNAVAILABLE, e.message ?: "无法调起系统浏览器", null)
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

    private fun handlePickBackupDirectory(result: MethodChannel.Result) {
        pendingPickDir?.error(ERROR_CANCELLED, "已取消上一次选择备份目录", null)
        pendingPickDir = result

        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
            )
        }
        try {
            activity.startActivityForResult(intent, REQUEST_CODE_PICK_DIRECTORY)
        } catch (e: Exception) {
            pendingPickDir = null
            result.error(ERROR_UNAVAILABLE, e.message ?: "无法打开系统文件夹选择器", null)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == REQUEST_CODE_SAVE_DOCUMENT) {
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

        if (requestCode == REQUEST_CODE_PICK_DIRECTORY) {
            val pending = pendingPickDir ?: return true
            pendingPickDir = null

            val treeUri = data?.data
            if (resultCode != Activity.RESULT_OK || treeUri == null) {
                pending.error(ERROR_CANCELLED, "已取消选择备份目录", null)
                return true
            }

            val persistFlags = Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            try {
                activity.contentResolver.takePersistableUriPermission(treeUri, persistFlags)
            } catch (_: Exception) {
                pending.error(ERROR_IO, "无法获取所选目录的持久读写权限", null)
                return true
            }

            val displayPath = buildTreeDisplayPath(treeUri)
            pending.success(
                mapOf(
                    "mode" to "androidSafTree",
                    "locator" to treeUri.toString(),
                    "displayPath" to displayPath,
                ),
            )
            return true
        }

        return false
    }

    private fun handleCheckDirectoryAccessible(call: MethodCall, result: MethodChannel.Result) {
        val locator = call.argument<String>("locator")?.trim().orEmpty()
        if (locator.isEmpty()) {
            result.success(false)
            return
        }
        val appContext = activity.applicationContext
        ioExecutor.execute {
            val accessible = try {
                val treeUri = Uri.parse(locator)
                val resolver = appContext.contentResolver
                val hasPersistedPerm = resolver.persistedUriPermissions.any { perm ->
                    perm.uri == treeUri && perm.isReadPermission && perm.isWritePermission
                }
                if (!hasPersistedPerm) {
                    false
                } else {
                    val treeDocId = DocumentsContract.getTreeDocumentId(treeUri)
                    val treeDocUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, treeDocId)
                    resolver.query(
                        treeDocUri,
                        arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID),
                        null,
                        null,
                        null,
                    )?.use { cursor ->
                        cursor.moveToFirst()
                    } == true
                }
            } catch (_: Exception) {
                false
            }
            mainHandler.post {
                result.success(accessible)
            }
        }
    }

    private fun handleListDirectoryBackups(call: MethodCall, result: MethodChannel.Result) {
        val locator = call.argument<String>("locator")?.trim().orEmpty()
        if (locator.isEmpty()) {
            result.error(ERROR_INVALID_ARGS, "缺少目录定位标识", null)
            return
        }
        val appContext = activity.applicationContext
        ioExecutor.execute {
            try {
                val treeUri = Uri.parse(locator)
                val resolver = appContext.contentResolver
                val treeDocId = DocumentsContract.getTreeDocumentId(treeUri)
                val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
                    treeUri,
                    treeDocId,
                )
                val items = ArrayList<Map<String, Any>>()
                val projection = arrayOf(
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_SIZE,
                    DocumentsContract.Document.COLUMN_LAST_MODIFIED,
                    DocumentsContract.Document.COLUMN_MIME_TYPE,
                )
                val cursor = resolver.query(childrenUri, projection, null, null, null)
                    ?: throw IOException("无法访问外部备份目录")
                cursor.use { c ->
                    val nameIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                    val sizeIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
                    val modIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
                    val mimeIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
                    while (c.moveToNext()) {
                        val mime = if (mimeIdx >= 0 && !c.isNull(mimeIdx)) c.getString(mimeIdx) else ""
                        if (mime == DocumentsContract.Document.MIME_TYPE_DIR) continue
                        val name = if (nameIdx >= 0 && !c.isNull(nameIdx)) c.getString(nameIdx) else ""
                        if (name.isBlank() || name.endsWith(".tmp", ignoreCase = true)) continue
                        val size = if (sizeIdx >= 0 && !c.isNull(sizeIdx)) c.getLong(sizeIdx) else 0L
                        val modMs = if (modIdx >= 0 && !c.isNull(modIdx)) c.getLong(modIdx) else 0L
                        items.add(
                            mapOf(
                                "fileName" to name,
                                "sizeBytes" to size,
                                "modifiedAtMs" to modMs,
                            ),
                        )
                    }
                }
                mainHandler.post {
                    result.success(items)
                }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error(ERROR_IO, e.message ?: "无法读取外部备份目录", null)
                }
            }
        }
    }

    private fun handleWriteDirectoryBackup(call: MethodCall, result: MethodChannel.Result) {
        val locator = call.argument<String>("locator")?.trim().orEmpty()
        val rawName = call.argument<String>("fileName")
        val bytes = call.argument<ByteArray>("bytes")
        val safeName = sanitizeFileName(rawName, fallback = "")
        if (locator.isEmpty() || safeName.isEmpty() || bytes == null) {
            result.error(ERROR_INVALID_ARGS, "写入外部备份目录参数无效", null)
            return
        }
        val appContext = activity.applicationContext
        ioExecutor.execute {
            try {
                val treeUri = Uri.parse(locator)
                val resolver = appContext.contentResolver
                val treeDocId = DocumentsContract.getTreeDocumentId(treeUri)
                val treeDocUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, treeDocId)
                val targetUri = findChildDocumentUri(resolver, treeUri, treeDocId, safeName)
                    ?: DocumentsContract.createDocument(
                        resolver,
                        treeDocUri,
                        guessMimeType(safeName),
                        safeName,
                    )
                    ?: throw IOException("无法在外部备份目录创建文件")
                writeAllBytesToUri(appContext, targetUri, bytes)
                mainHandler.post {
                    result.success(null)
                }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error(ERROR_IO, e.message ?: "写入外部备份文件失败", null)
                }
            }
        }
    }

    private fun handleReadDirectoryBackup(call: MethodCall, result: MethodChannel.Result) {
        val locator = call.argument<String>("locator")?.trim().orEmpty()
        val rawName = call.argument<String>("fileName")
        val safeName = sanitizeFileName(rawName, fallback = "")
        if (locator.isEmpty() || safeName.isEmpty()) {
            result.error(ERROR_INVALID_ARGS, "读取外部备份文件参数无效", null)
            return
        }
        val appContext = activity.applicationContext
        ioExecutor.execute {
            try {
                val treeUri = Uri.parse(locator)
                val resolver = appContext.contentResolver
                val treeDocId = DocumentsContract.getTreeDocumentId(treeUri)
                val targetUri = findChildDocumentUri(resolver, treeUri, treeDocId, safeName)
                    ?: throw IOException("外部备份文件不存在")
                val bytes = resolver.openInputStream(targetUri)?.use { input ->
                    input.readBytes()
                } ?: throw IOException("无法打开外部备份文件输入流")
                mainHandler.post {
                    result.success(bytes)
                }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error(ERROR_IO, e.message ?: "读取外部备份文件失败", null)
                }
            }
        }
    }

    private fun handleDeleteDirectoryBackup(call: MethodCall, result: MethodChannel.Result) {
        val locator = call.argument<String>("locator")?.trim().orEmpty()
        val rawName = call.argument<String>("fileName")
        val safeName = sanitizeFileName(rawName, fallback = "")
        if (locator.isEmpty() || safeName.isEmpty()) {
            result.error(ERROR_INVALID_ARGS, "删除外部备份文件参数无效", null)
            return
        }
        val appContext = activity.applicationContext
        ioExecutor.execute {
            try {
                val treeUri = Uri.parse(locator)
                val resolver = appContext.contentResolver
                val treeDocId = DocumentsContract.getTreeDocumentId(treeUri)
                val targetUri = findChildDocumentUri(resolver, treeUri, treeDocId, safeName)
                if (targetUri != null) {
                    DocumentsContract.deleteDocument(resolver, targetUri)
                }
                mainHandler.post {
                    result.success(null)
                }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error(ERROR_IO, e.message ?: "删除外部备份文件失败", null)
                }
            }
        }
    }

    private fun findChildDocumentUri(
        resolver: ContentResolver,
        treeUri: Uri,
        treeDocId: String,
        targetName: String,
    ): Uri? {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, treeDocId)
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        )
        resolver.query(childrenUri, projection, null, null, null)?.use { c ->
            val idIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            while (c.moveToNext()) {
                val name = if (nameIdx >= 0 && !c.isNull(nameIdx)) c.getString(nameIdx) else ""
                if (name == targetName && idIdx >= 0 && !c.isNull(idIdx)) {
                    return DocumentsContract.buildDocumentUriUsingTree(treeUri, c.getString(idIdx))
                }
            }
        }
        return null
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
            if (out is FileOutputStream) {
                try {
                    out.fd.sync()
                } catch (_: Exception) {
                }
            }
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
        const val CHANNEL_NAME = "com.tallyisle/files"
        const val REQUEST_CODE_SAVE_DOCUMENT = 4035
        const val REQUEST_CODE_PICK_DIRECTORY = 4036

        private const val EXPORTS_SUBDIR = "exports"
        private const val SHARED_EXPORTS_NAME = "shared_exports"
        private const val EXPORT_CACHE_TTL_MS = 24L * 60L * 60L * 1000L

        private const val ERROR_CANCELLED = "CANCELLED"
        private const val ERROR_INVALID_ARGS = "INVALID_ARGS"
        private const val ERROR_IO = "IO_ERROR"
        private const val ERROR_UNAVAILABLE = "UNAVAILABLE"

        fun buildTreeDisplayPath(treeUri: Uri): String {
            val docId = try {
                DocumentsContract.getTreeDocumentId(treeUri)
            } catch (_: Exception) {
                ""
            }
            if (docId.startsWith("primary:")) {
                val rel = docId.removePrefix("primary:").trim('/')
                return if (rel.isEmpty()) "内部存储" else "内部存储/$rel"
            }
            if (docId.startsWith("home:")) {
                val rel = docId.removePrefix("home:").trim('/')
                return if (rel.isEmpty()) "文档" else "文档/$rel"
            }
            if (docId.contains(':')) {
                val parts = docId.split(':', limit = 2)
                val vol = parts[0]
                val rel = parts[1].trim('/')
                return if (rel.isEmpty()) "外部存储 ($vol)" else "外部存储 ($vol)/$rel"
            }
            return docId.ifEmpty { treeUri.lastPathSegment ?: treeUri.toString() }
        }

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
