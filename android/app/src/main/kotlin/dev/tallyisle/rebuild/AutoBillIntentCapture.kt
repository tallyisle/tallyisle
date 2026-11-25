package dev.tallyisle.rebuild

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.webkit.MimeTypeMap
import java.io.File

/**
 * Converts incoming system intents (share sheet, selected-text menu, static shortcuts, tile and
 * widget buttons) into `onSharedPayload` maps for Flutter. `content://` image streams are copied
 * to `cacheDir/shared_automation/share_<ts>_<i>.<ext>` so Dart receives readable file paths.
 */
object AutoBillIntentCapture {
    private const val SHARE_DIR = "shared_automation"
    private const val MAX_IMAGES = 9
    private const val MAX_TEXT_CHARS = 20_000
    private const val STALE_FILE_AGE_MS = 24L * 60L * 60L * 1000L

    /** `true` when [intent] is one of the system actions handled by [capture]. */
    fun isCapturable(intent: Intent?): Boolean {
        val action = intent?.action ?: return false
        return action == Intent.ACTION_SEND ||
            action == Intent.ACTION_SEND_MULTIPLE ||
            action == Intent.ACTION_PROCESS_TEXT ||
            action == AutomationBridge.ACTION_SHORTCUT ||
            intent.hasExtra(AutomationBridge.EXTRA_SHORTCUT_ACTION)
    }

    /**
     * Builds payloads for [intent] (possibly empty) and clears the handled intent state so that
     * activity re-creation can never replay it. Image copying may touch the disk.
     */
    fun capture(context: Context, intent: Intent): List<Map<String, Any?>> {
        val now = System.currentTimeMillis()
        val payloads = ArrayList<Map<String, Any?>>()
        val shortcut = intent.getStringExtra(AutomationBridge.EXTRA_SHORTCUT_ACTION)
        when {
            shortcut != null -> {
                if (shortcut in AutomationBridge.SHORTCUT_ACTIONS) {
                    val source = intent.getStringExtra(AutomationBridge.EXTRA_SHORTCUT_SOURCE)
                        ?: AutomationBridge.SOURCE_SHORTCUT
                    payloads.add(
                        payload(
                            kind = "shortcut",
                            shortcutAction = shortcut,
                            source = source,
                            receivedAtMs = now,
                        ),
                    )
                }
            }
            intent.action == Intent.ACTION_PROCESS_TEXT -> {
                val text = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
                    ?.trim().orEmpty()
                if (text.isNotEmpty()) {
                    payloads.add(
                        payload(
                            kind = "text",
                            text = text.take(MAX_TEXT_CHARS),
                            source = "process_text",
                            receivedAtMs = now,
                        ),
                    )
                }
            }
            intent.action == Intent.ACTION_SEND || intent.action == Intent.ACTION_SEND_MULTIPLE -> {
                val uris = collectUris(intent)
                val images = if (uris.isNotEmpty()) copyImages(context, uris, now) else emptyList()
                val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
                    ?.trim().orEmpty()
                if (images.isNotEmpty()) {
                    payloads.add(
                        payload(
                            kind = "image",
                            imagePaths = images,
                            source = "share",
                            receivedAtMs = now,
                        ),
                    )
                } else if (text.isNotEmpty()) {
                    payloads.add(
                        payload(
                            kind = "text",
                            text = text.take(MAX_TEXT_CHARS),
                            source = "share",
                            receivedAtMs = now,
                        ),
                    )
                }
            }
        }
        clearHandled(intent)
        return payloads
    }

    /** Strips handled share / shortcut state so activity re-creation can never replay it. */
    fun clearHandled(intent: Intent) {
        intent.removeExtra(AutomationBridge.EXTRA_SHORTCUT_ACTION)
        intent.removeExtra(AutomationBridge.EXTRA_SHORTCUT_SOURCE)
        intent.removeExtra(Intent.EXTRA_STREAM)
        intent.removeExtra(Intent.EXTRA_TEXT)
        intent.removeExtra(Intent.EXTRA_PROCESS_TEXT)
        intent.clipData = null
        intent.action = Intent.ACTION_MAIN
    }

    private fun payload(
        kind: String,
        text: String? = null,
        imagePaths: List<String>? = null,
        shortcutAction: String? = null,
        source: String?,
        receivedAtMs: Long,
    ): Map<String, Any?> {
        val map = LinkedHashMap<String, Any?>()
        map["kind"] = kind
        map["text"] = text
        map["imagePaths"] = imagePaths
        map["shortcutAction"] = shortcutAction
        map["source"] = source
        map["receivedAtMs"] = receivedAtMs
        return map
    }

    @Suppress("DEPRECATION")
    private fun collectUris(intent: Intent): List<Uri> {
        val out = LinkedHashSet<Uri>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)?.let { out.add(it) }
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                ?.let { out.addAll(it) }
        } else {
            val single = intent.getParcelableExtra<android.os.Parcelable>(Intent.EXTRA_STREAM)
            if (single is Uri) out.add(single)
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { out.addAll(it) }
        }
        val clip = intent.clipData
        if (clip != null) {
            for (i in 0 until clip.itemCount) {
                clip.getItemAt(i).uri?.let { out.add(it) }
            }
        }
        return out.toList()
    }

    private fun copyImages(context: Context, uris: List<Uri>, timestamp: Long): List<String> {
        val dir = File(context.cacheDir, SHARE_DIR)
        if (!dir.exists() && !dir.mkdirs()) return emptyList()
        pruneStaleFiles(dir, timestamp)
        val out = ArrayList<String>()
        var index = 0
        for (uri in uris) {
            if (out.size >= MAX_IMAGES) break
            val mime = try {
                context.contentResolver.getType(uri)
            } catch (_: Exception) {
                null
            }
            if (mime != null && !mime.startsWith("image/")) continue
            val target = File(dir, "share_${timestamp}_$index.${extensionFor(uri, mime)}")
            try {
                val input = context.contentResolver.openInputStream(uri) ?: continue
                input.use { source ->
                    target.outputStream().use { sink -> source.copyTo(sink) }
                }
                if (target.length() > 0L) {
                    out.add(target.absolutePath)
                    index += 1
                } else {
                    target.delete()
                }
            } catch (_: Exception) {
                target.delete()
            }
        }
        return out
    }

    private fun extensionFor(uri: Uri, mime: String?): String {
        val fromMime = mime?.let { MimeTypeMap.getSingleton().getExtensionFromMimeType(it) }
        if (!fromMime.isNullOrEmpty()) return fromMime
        val fromPath = uri.lastPathSegment?.substringAfterLast('.', "")?.lowercase().orEmpty()
        if (fromPath.length in 2..5 && fromPath.all { it.isLetterOrDigit() }) return fromPath
        return "jpg"
    }

    private fun pruneStaleFiles(dir: File, now: Long) {
        val files = dir.listFiles() ?: return
        for (file in files) {
            if (now - file.lastModified() > STALE_FILE_AGE_MS) file.delete()
        }
    }
}
