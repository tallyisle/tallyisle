package dev.tallyisle.rebuild

import android.accessibilityservice.AccessibilityService
import android.content.ComponentName
import android.content.Context
import android.provider.Settings
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONArray
import org.json.JSONObject

data class CapturedAccessibilityEvent(
    val packageName: String,
    val rawText: String,
    val capturedAtMs: Long,
) {
    fun toMap(): Map<String, Any> = mapOf(
        "packageName" to packageName,
        "rawText" to rawText,
        "capturedAtMs" to capturedAtMs,
    )
}

/**
 * Local-only Android AccessibilityService for capturing payment confirmation / notification
 * texts from supported payment & SMS apps and queueing them for draft review (`F-020`).
 *
 * Never uploads screen data anywhere; all parsing and confirmation happen locally in TallyIsle.
 */
class AutoBillAccessibilityService : AccessibilityService() {
    private var lastSignature: String = ""
    private var lastCapturedAtMs: Long = 0L

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        val pkg = event.packageName?.toString()?.trim().orEmpty()
        if (pkg.isEmpty() || pkg !in SUPPORTED_PACKAGES) return

        val collected = LinkedHashSet<String>()
        for (seq in event.text) {
            val s = seq?.toString()?.trim().orEmpty()
            if (s.isNotEmpty()) {
                collected.add(s)
            }
        }
        val contentDesc = event.contentDescription?.toString()?.trim().orEmpty()
        if (contentDesc.isNotEmpty()) {
            collected.add(contentDesc)
        }

        val root = rootInActiveWindow
        if (root != null && root.packageName?.toString() == pkg) {
            collectNodeTexts(root, collected, depth = 0)
        }

        if (collected.isEmpty()) return
        val joined = collected.joinToString("\n")
        if (!looksLikePaymentText(joined)) return

        val now = System.currentTimeMillis()
        val signature = "$pkg|$joined"
        if (signature == lastSignature && (now - lastCapturedAtMs) in 0 until DEDUP_WINDOW_MS) {
            return
        }
        lastSignature = signature
        lastCapturedAtMs = now

        val captured = CapturedAccessibilityEvent(
            packageName = pkg,
            rawText = joined,
            capturedAtMs = now,
        )
        enqueueCapturedEvent(applicationContext, captured)
    }

    override fun onInterrupt() {
        // No active feedback resources to release.
    }

    private fun collectNodeTexts(
        node: AccessibilityNodeInfo,
        out: MutableSet<String>,
        depth: Int,
    ) {
        if (depth > MAX_TREE_DEPTH || out.size >= MAX_COLLECTED_LINES) return
        val nodeText = node.text?.toString()?.trim().orEmpty()
        if (nodeText.isNotEmpty() && nodeText.length <= MAX_SINGLE_LINE_CHARS) {
            out.add(nodeText)
        }
        val desc = node.contentDescription?.toString()?.trim().orEmpty()
        if (desc.isNotEmpty() && desc.length <= MAX_SINGLE_LINE_CHARS) {
            out.add(desc)
        }
        val count = node.childCount
        for (i in 0 until count) {
            if (out.size >= MAX_COLLECTED_LINES) break
            val child = node.getChild(i) ?: continue
            collectNodeTexts(child, out, depth + 1)
        }
    }

    companion object {
        private const val INBOX_PREFS = "tallyisle_automation_inbox"
        private const val KEY_CAPTURED_EVENTS = "captured_events_json"
        private const val MAX_QUEUED_EVENTS = 50
        private const val MAX_COLLECTED_LINES = 40
        private const val MAX_TREE_DEPTH = 12
        private const val MAX_SINGLE_LINE_CHARS = 200
        private const val DEDUP_WINDOW_MS = 5000L

        val SUPPORTED_PACKAGES: Set<String> = setOf(
            "com.tencent.mm",
            "com.eg.android.AlipayGphone",
            "com.unionpay",
            "cn.gov.pbc.dcep",
            "com.jingdong.app.mall",
            "com.jd.jrapp",
            "com.sankuai.meituan",
            "com.sankuai.meituan.takeoutnew",
            "com.xunmeng.pinduoduo",
            "com.android.mms",
            "com.google.android.apps.messaging",
        )

        private val PAYMENT_CUE_KEYWORDS = listOf(
            "¥",
            "￥",
            "元",
            "支付",
            "付款",
            "消费",
            "收款",
            "转账",
            "扣款",
            "入账",
            "还款",
        )

        @Volatile
        internal var liveListener: ((CapturedAccessibilityEvent) -> Boolean)? = null

        fun isServiceEnabled(context: Context): Boolean {
            val appContext = context.applicationContext
            val enabledFlag = try {
                Settings.Secure.getInt(
                    appContext.contentResolver,
                    Settings.Secure.ACCESSIBILITY_ENABLED,
                    0,
                )
            } catch (_: Exception) {
                0
            }
            if (enabledFlag != 1) return false

            val rawServices = try {
                Settings.Secure.getString(
                    appContext.contentResolver,
                    Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
                )
            } catch (_: Exception) {
                null
            } ?: return false

            val expected = ComponentName(
                appContext.packageName,
                AutoBillAccessibilityService::class.java.name,
            )
            for (token in rawServices.split(':')) {
                val trimmed = token.trim()
                if (trimmed.isEmpty()) continue
                val parsed = ComponentName.unflattenFromString(trimmed)
                if (parsed == expected) return true
            }
            return false
        }

        internal fun looksLikePaymentText(text: String): Boolean {
            val hasDigit = text.any { it in '0'..'9' }
            if (!hasDigit) return false
            return PAYMENT_CUE_KEYWORDS.any { cue -> text.contains(cue) }
        }

        @Synchronized
        internal fun enqueueCapturedEvent(context: Context, event: CapturedAccessibilityEvent) {
            val listener = liveListener
            if (listener != null && listener(event)) {
                return
            }
            val prefs = context.getSharedPreferences(INBOX_PREFS, Context.MODE_PRIVATE)
            val existing = readQueueLocked(prefs.getString(KEY_CAPTURED_EVENTS, null)).toMutableList()
            existing.add(event)
            while (existing.size > MAX_QUEUED_EVENTS) {
                existing.removeAt(0)
            }
            val arr = JSONArray()
            for (item in existing) {
                arr.put(
                    JSONObject().apply {
                        put("packageName", item.packageName)
                        put("rawText", item.rawText)
                        put("capturedAtMs", item.capturedAtMs)
                    },
                )
            }
            prefs.edit().putString(KEY_CAPTURED_EVENTS, arr.toString()).commit()
        }

        @Synchronized
        fun consumePersistedEvents(context: Context): List<CapturedAccessibilityEvent> {
            val prefs = context.applicationContext.getSharedPreferences(
                INBOX_PREFS,
                Context.MODE_PRIVATE,
            )
            val raw = prefs.getString(KEY_CAPTURED_EVENTS, null) ?: return emptyList()
            prefs.edit().remove(KEY_CAPTURED_EVENTS).commit()
            return readQueueLocked(raw)
        }

        private fun readQueueLocked(raw: String?): List<CapturedAccessibilityEvent> {
            if (raw.isNullOrBlank()) return emptyList()
            return try {
                val arr = JSONArray(raw)
                buildList(arr.length()) {
                    for (i in 0 until arr.length()) {
                        val obj = arr.optJSONObject(i) ?: continue
                        val pkg = obj.optString("packageName", "").trim()
                        val text = obj.optString("rawText", "").trim()
                        val ts = obj.optLong("capturedAtMs", 0L)
                        if (text.isNotEmpty()) {
                            add(CapturedAccessibilityEvent(pkg, text, ts))
                        }
                    }
                }
            } catch (_: Exception) {
                emptyList()
            }
        }
    }
}
