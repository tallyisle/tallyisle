package dev.tallyisle.rebuild

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject
import java.math.BigDecimal
import java.math.RoundingMode

/** One raw payment text captured by the notification listener or the accessibility service. */
data class CapturedPaymentEvent(
    val packageName: String,
    val rawText: String,
    val capturedAtMs: Long,
    val channel: String? = null,
) {
    fun toMap(): Map<String, Any?> {
        val map = LinkedHashMap<String, Any?>()
        map["packageName"] = packageName
        map["rawText"] = rawText
        map["capturedAtMs"] = capturedAtMs
        map["channel"] = channel
        return map
    }
}

/** Selectable category / asset option mirrored from Flutter for the native prompt overlay. */
data class PromptOption(
    val id: Int,
    val name: String,
    val recordType: Int?,
)

/** Android-side snapshot of `AutoBillSettings` pushed by `syncAndroidAutoBillConfig`. */
data class AutoBillNativeConfig(
    val enableNotificationCapture: Boolean,
    val enableAccessibilityCapture: Boolean,
    val promptMode: String,
    val categories: List<PromptOption>,
    val assets: List<PromptOption>,
)

/**
 * Process-wide inbox shared by `AutoBillNotificationListenerService` and
 * `AutoBillAccessibilityService` (`SharedPreferences("tallyisle_automation_inbox")`).
 *
 * Responsibilities:
 *  - business switches / prompt mode / category+asset cache pushed from Flutter,
 *  - cross-channel 15 second de-duplication of captured payment texts,
 *  - persistent queues for captured events, shared payloads and prompt actions that could not be
 *    delivered live to a Flutter engine,
 *  - live listeners registered by [AutomationBridge] while the Flutter engine is attached.
 */
object AutoBillNativeInbox {
    const val PREFS_NAME = "tallyisle_automation_inbox"
    const val CHANNEL_NOTIFICATION = "notification"
    const val CHANNEL_ACCESSIBILITY = "accessibility"
    const val PROMPT_MODE_NOTIFICATION = "notification"
    const val PROMPT_MODE_OVERLAY = "overlay"
    const val PROMPT_MODE_SILENT = "silent"
    const val DEDUP_WINDOW_MS = 15_000L

    private const val KEY_CAPTURED_EVENTS = "captured_events_json"
    private const val KEY_SHARED_PAYLOADS = "shared_payloads_json"
    private const val KEY_PROMPT_ACTIONS = "prompt_actions_json"
    private const val KEY_ENABLE_NOTIFICATION = "enable_notification_capture"
    private const val KEY_ENABLE_ACCESSIBILITY = "enable_accessibility_capture"
    private const val KEY_PROMPT_MODE = "prompt_mode"
    private const val KEY_CATEGORIES = "categories_json"
    private const val KEY_ASSETS = "assets_json"
    private const val MAX_QUEUED = 50

    val PAYMENT_APP_PACKAGES: Set<String> = setOf(
        "com.tencent.mm",
        "com.eg.android.AlipayGphone",
        "com.unionpay",
        "cn.gov.pbc.dcep",
        "com.jingdong.app.mall",
        "com.jd.jrapp",
        "com.sankuai.meituan",
        "com.sankuai.meituan.takeoutnew",
        "com.xunmeng.pinduoduo",
        "com.ss.android.ugc.aweme",
    )

    val BANK_APP_PACKAGES: Set<String> = setOf(
        "com.icbc",
        "com.chinamworld.main",
        "com.android.bankabc",
        "com.chinamworld.bocmbci",
        "cmb.pb",
        "com.cmbchina.ccd.pluto.cmbActivity",
        "com.bankcomm.Bankcomm",
        "com.yitong.mbank.psbc",
        "com.ecitic.bank.mobile",
        "com.cebbank.mobile.cemb",
        "cn.com.spdb.mobilebank.per",
        "cn.com.cmbc.newmbank",
        "com.cib.cibmb",
        "com.pingan.paces.ccms",
        "com.cgbchina.xpt",
        "com.zabank.app",
    )

    val SMS_APP_PACKAGES: Set<String> = setOf(
        "com.android.mms",
        "com.google.android.apps.messaging",
        "com.samsung.android.messaging",
        "com.huawei.message",
        "com.hihonor.mms",
        "com.miui.mms",
    )

    val ALL_SUPPORTED_PACKAGES: Set<String> =
        PAYMENT_APP_PACKAGES + BANK_APP_PACKAGES + SMS_APP_PACKAGES

    private val PAYMENT_CUE_KEYWORDS = listOf(
        "¥", "￥", "元", "支付", "付款", "消费", "收款", "转账", "扣款", "入账", "还款", "退款",
    )

    private val AMOUNT_AFTER_SYMBOL = Regex("""[¥￥]\s*-?(\d[\d,]*(?:\.\d{1,2})?)""")
    private val AMOUNT_BEFORE_YUAN = Regex("""(\d[\d,]*(?:\.\d{1,2})?)\s*元""")

    /** Live delivery hooks, non-null only while a Flutter engine is attached. */
    @Volatile
    internal var eventListener: ((CapturedPaymentEvent) -> Boolean)? = null

    @Volatile
    internal var sharedListener: ((Map<String, Any?>) -> Boolean)? = null

    @Volatile
    internal var actionListener: ((Map<String, Any?>) -> Boolean)? = null

    private val lock = Any()

    private class Fingerprint(
        val packageName: String,
        val amounts: Set<String>,
        val textKey: String,
        val channel: String?,
        var seenAtMs: Long,
    )

    private val recentFingerprints = ArrayList<Fingerprint>()

    private fun prefs(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    // ---------------------------------------------------------------- config

    fun saveConfig(
        context: Context,
        enableNotificationCapture: Boolean,
        enableAccessibilityCapture: Boolean,
        promptMode: String,
        categories: List<Map<*, *>>,
        assets: List<Map<*, *>>,
    ) {
        val mode = when (promptMode) {
            PROMPT_MODE_OVERLAY, PROMPT_MODE_SILENT -> promptMode
            else -> PROMPT_MODE_NOTIFICATION
        }
        synchronized(lock) {
            prefs(context).edit()
                .putBoolean(KEY_ENABLE_NOTIFICATION, enableNotificationCapture)
                .putBoolean(KEY_ENABLE_ACCESSIBILITY, enableAccessibilityCapture)
                .putString(KEY_PROMPT_MODE, mode)
                .putString(KEY_CATEGORIES, optionsToJson(categories).toString())
                .putString(KEY_ASSETS, optionsToJson(assets).toString())
                .commit()
        }
    }

    fun loadConfig(context: Context): AutoBillNativeConfig {
        val p = prefs(context)
        return AutoBillNativeConfig(
            enableNotificationCapture = p.getBoolean(KEY_ENABLE_NOTIFICATION, true),
            enableAccessibilityCapture = p.getBoolean(KEY_ENABLE_ACCESSIBILITY, true),
            promptMode = p.getString(KEY_PROMPT_MODE, PROMPT_MODE_NOTIFICATION)
                ?: PROMPT_MODE_NOTIFICATION,
            categories = optionsFromJson(p.getString(KEY_CATEGORIES, null)),
            assets = optionsFromJson(p.getString(KEY_ASSETS, null)),
        )
    }

    private fun optionsToJson(raw: List<Map<*, *>>): JSONArray {
        val arr = JSONArray()
        for (item in raw) {
            val id = (item["id"] as? Number)?.toInt() ?: continue
            val name = (item["name"] as? String)?.trim().orEmpty()
            if (name.isEmpty()) continue
            val obj = JSONObject()
            obj.put("id", id)
            obj.put("name", name)
            val type = (item["recordType"] as? Number)?.toInt()
                ?: (item["type"] as? Number)?.toInt()
            if (type != null) obj.put("recordType", type)
            arr.put(obj)
        }
        return arr
    }

    private fun optionsFromJson(raw: String?): List<PromptOption> {
        if (raw.isNullOrBlank()) return emptyList()
        return try {
            val arr = JSONArray(raw)
            val out = ArrayList<PromptOption>(arr.length())
            for (i in 0 until arr.length()) {
                val obj = arr.optJSONObject(i) ?: continue
                val name = obj.optString("name", "")
                if (name.isEmpty() || !obj.has("id")) continue
                out.add(
                    PromptOption(
                        id = obj.optInt("id"),
                        name = name,
                        recordType = if (obj.has("recordType")) obj.optInt("recordType") else null,
                    ),
                )
            }
            out
        } catch (_: Exception) {
            emptyList()
        }
    }

    // ------------------------------------------------------- captured events

    internal fun looksLikePaymentText(text: String): Boolean {
        if (text.none { it in '0'..'9' }) return false
        return PAYMENT_CUE_KEYWORDS.any { cue -> text.contains(cue) }
    }

    /**
     * Entry point for both capture channels. Applies the business switch of the channel, the
     * payment-text heuristic and the cross-channel 15 second de-duplication, then delivers the
     * event live or persists it. Returns `true` when the event was accepted.
     */
    fun ingestCaptured(context: Context, event: CapturedPaymentEvent): Boolean {
        val appContext = context.applicationContext
        val config = loadConfig(appContext)
        val allowed = when (event.channel) {
            CHANNEL_NOTIFICATION -> config.enableNotificationCapture
            CHANNEL_ACCESSIBILITY -> config.enableAccessibilityCapture
            else -> true
        }
        if (!allowed) return false
        if (!looksLikePaymentText(event.rawText)) return false
        if (isDuplicate(event)) return false

        val listener = eventListener
        if (listener != null && listener(event)) return true
        persistEvent(appContext, event)
        if (listener == null && config.promptMode != PROMPT_MODE_SILENT) {
            AutoBillPromptNotifier.postCaptureFallback(appContext)
        }
        return true
    }

    private fun extractAmounts(text: String): Set<String> {
        val out = LinkedHashSet<String>()
        for (regex in listOf(AMOUNT_AFTER_SYMBOL, AMOUNT_BEFORE_YUAN)) {
            for (match in regex.findAll(text)) {
                val digits = match.groupValues[1].replace(",", "")
                try {
                    out.add(BigDecimal(digits).setScale(2, RoundingMode.HALF_UP).toPlainString())
                } catch (_: NumberFormatException) {
                    // Ignore malformed numerals.
                }
            }
        }
        return out
    }

    private fun isDuplicate(event: CapturedPaymentEvent): Boolean {
        val now = event.capturedAtMs
        val amounts = extractAmounts(event.rawText)
        val textKey = event.rawText.filterNot { it.isWhitespace() }
        synchronized(lock) {
            recentFingerprints.removeAll { now - it.seenAtMs !in 0 until DEDUP_WINDOW_MS }
            for (fp in recentFingerprints) {
                if (fp.packageName != event.packageName) continue
                // Cross-channel merge: the richer notification payload always wins, so a sparse
                // accessibility scrape never suppresses a notification that arrives after it.
                if (fp.channel != event.channel &&
                    event.channel == CHANNEL_NOTIFICATION
                ) {
                    continue
                }
                val sameAmount = amounts.isNotEmpty() && fp.amounts.any { it in amounts }
                if (sameAmount || fp.textKey == textKey) {
                    fp.seenAtMs = now
                    return true
                }
            }
            recentFingerprints.add(
                Fingerprint(event.packageName, amounts, textKey, event.channel, now),
            )
            return false
        }
    }

    fun persistEvent(context: Context, event: CapturedPaymentEvent) {
        val obj = JSONObject()
        obj.put("packageName", event.packageName)
        obj.put("rawText", event.rawText)
        obj.put("capturedAtMs", event.capturedAtMs)
        if (event.channel != null) obj.put("channel", event.channel)
        enqueueJson(context, KEY_CAPTURED_EVENTS, obj)
    }

    fun consumePersistedEvents(context: Context): List<CapturedPaymentEvent> {
        val out = ArrayList<CapturedPaymentEvent>()
        for (obj in consumeJson(context, KEY_CAPTURED_EVENTS)) {
            val text = obj.optString("rawText", "").trim()
            if (text.isEmpty()) continue
            out.add(
                CapturedPaymentEvent(
                    packageName = obj.optString("packageName", "").trim(),
                    rawText = text,
                    capturedAtMs = obj.optLong("capturedAtMs", 0L),
                    channel = if (obj.has("channel")) obj.optString("channel") else null,
                ),
            )
        }
        return out
    }

    // ------------------------------------------------------- shared payloads

    fun enqueueSharedPayload(context: Context, payload: Map<String, Any?>) {
        enqueueJson(context, KEY_SHARED_PAYLOADS, mapToJson(payload))
    }

    fun consumeSharedPayloads(context: Context): List<Map<String, Any?>> =
        consumeJson(context, KEY_SHARED_PAYLOADS).map { jsonToMap(it) }

    // -------------------------------------------------------- prompt actions

    fun enqueuePromptAction(context: Context, action: Map<String, Any?>) {
        enqueueJson(context, KEY_PROMPT_ACTIONS, mapToJson(action))
    }

    fun consumePromptActions(context: Context): List<Map<String, Any?>> =
        consumeJson(context, KEY_PROMPT_ACTIONS).map { jsonToMap(it) }

    /**
     * Delivers a prompt action to the live Flutter engine, or queues it when none is attached.
     * Returns `true` when handed to a live engine.
     */
    fun dispatchPromptAction(context: Context, action: Map<String, Any?>): Boolean {
        val listener = actionListener
        if (listener != null && listener(action)) return true
        enqueuePromptAction(context, action)
        return false
    }

    // ------------------------------------------------------------ JSON queue

    private fun enqueueJson(context: Context, key: String, obj: JSONObject) {
        synchronized(lock) {
            val p = prefs(context)
            val existing = parseArray(p.getString(key, null))
            existing.put(obj)
            val trimmed = if (existing.length() > MAX_QUEUED) {
                val copy = JSONArray()
                for (i in existing.length() - MAX_QUEUED until existing.length()) {
                    copy.put(existing.get(i))
                }
                copy
            } else {
                existing
            }
            p.edit().putString(key, trimmed.toString()).commit()
        }
    }

    private fun consumeJson(context: Context, key: String): List<JSONObject> {
        synchronized(lock) {
            val p = prefs(context)
            val raw = p.getString(key, null) ?: return emptyList()
            p.edit().remove(key).commit()
            val arr = parseArray(raw)
            val out = ArrayList<JSONObject>(arr.length())
            for (i in 0 until arr.length()) {
                arr.optJSONObject(i)?.let { out.add(it) }
            }
            return out
        }
    }

    private fun parseArray(raw: String?): JSONArray {
        if (raw.isNullOrBlank()) return JSONArray()
        return try {
            JSONArray(raw)
        } catch (_: Exception) {
            JSONArray()
        }
    }

    private fun mapToJson(map: Map<String, Any?>): JSONObject {
        val obj = JSONObject()
        for ((k, v) in map) {
            if (v == null) continue
            if (v is Collection<*>) {
                val arr = JSONArray()
                for (item in v) arr.put(item)
                obj.put(k, arr)
            } else {
                obj.put(k, v)
            }
        }
        return obj
    }

    private fun jsonToMap(obj: JSONObject): Map<String, Any?> {
        val out = LinkedHashMap<String, Any?>()
        val keys = obj.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            val value: Any? = obj.opt(key)
            if (value == null || value == JSONObject.NULL) continue
            if (value is JSONArray) {
                val list = ArrayList<Any?>(value.length())
                for (i in 0 until value.length()) list.add(value.opt(i))
                out[key] = list
            } else {
                out[key] = value
            }
        }
        return out
    }
}
