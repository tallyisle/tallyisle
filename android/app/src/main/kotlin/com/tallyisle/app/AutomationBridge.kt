package com.tallyisle.app

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Unified Android native MethodChannel bridge (`com.tallyisle/automation`) for:
 *  - `F-033` `tallyisle://` external deep-link capture & live dispatch
 *  - `F-034` Desktop AppWidget snapshot sync & pin requests (4 widget kinds)
 *  - `F-020` notification listener / accessibility / overlay permission status & settings jumps
 *  - captured payment events, system share / shortcut payloads, notification prompt actions
 *  - offline Chinese OCR (bundled ML Kit, no Google Play Services)
 *
 * Methods: consumePendingDeepLink, getAccessibilityStatus, openAccessibilitySettings,
 * getNotificationListenerStatus, openNotificationListenerSettings, getOverlayPermissionStatus,
 * openOverlaySettings, syncAndroidAutoBillConfig, showAutoBillPrompt, consumeCapturedEvents,
 * consumePendingSharedPayloads, consumePendingPromptActions, recognizeImageOffline,
 * updateWidgetSnapshot, getActiveWidgetCounts, requestPinWidget.
 * Callbacks: onDeepLink, onCapturedEvent, onSharedPayload, onPromptAction.
 *
 * The clipboard is never read automatically.
 */
class AutomationBridge(
    context: Context,
    private val activity: Activity? = context as? Activity,
) {
    private val appContext: Context = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var pendingDeepLinkUri: String? = null

    private val eventListener: (CapturedPaymentEvent) -> Boolean = { event ->
        invokeFlutter("onCapturedEvent", event.toMap()) {
            AutoBillNativeInbox.persistEvent(appContext, event)
        }
    }
    private val sharedListener: (Map<String, Any?>) -> Boolean = { payload ->
        invokeFlutter("onSharedPayload", payload) {
            AutoBillNativeInbox.enqueueSharedPayload(appContext, payload)
        }
    }
    private val actionListener: (Map<String, Any?>) -> Boolean = { action ->
        invokeFlutter("onPromptAction", action) {
            AutoBillNativeInbox.enqueuePromptAction(appContext, action)
        }
    }

    fun attach(messenger: BinaryMessenger) {
        val mc = MethodChannel(messenger, CHANNEL_NAME)
        mc.setMethodCallHandler(::handleMethodCall)
        channel = mc
        AutoBillNativeInbox.eventListener = eventListener
        AutoBillNativeInbox.sharedListener = sharedListener
        AutoBillNativeInbox.actionListener = actionListener
    }

    fun detach() {
        if (AutoBillNativeInbox.eventListener === eventListener) {
            AutoBillNativeInbox.eventListener = null
        }
        if (AutoBillNativeInbox.sharedListener === sharedListener) {
            AutoBillNativeInbox.sharedListener = null
        }
        if (AutoBillNativeInbox.actionListener === actionListener) {
            AutoBillNativeInbox.actionListener = null
        }
        channel?.setMethodCallHandler(null)
        channel = null
    }

    /**
     * Captures an incoming `tallyisle://` deep-link [Intent] from `onCreate`
     * or `onNewIntent`. Returns `true` when the intent carried a supported external URI.
     */
    fun captureIntent(incomingIntent: Intent?, notifyFlutter: Boolean = true): Boolean {
        val data: Uri = incomingIntent?.data ?: return false
        val scheme = data.scheme?.lowercase().orEmpty()
        if (scheme != "tallyisle") return false
        val host = data.host?.lowercase().orEmpty()
        if (host == "reminder" || host == "reminder-open") return false

        val uriText = data.toString()
        incomingIntent.data = null
        pendingDeepLinkUri = uriText

        val activeChannel = channel
        if (notifyFlutter && activeChannel != null) {
            // The URI stays pending until Dart acknowledges it by returning `true`.
            mainHandler.post {
                activeChannel.invokeMethod(
                    "onDeepLink",
                    uriText,
                    object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            if (result == true && pendingDeepLinkUri == uriText) {
                                pendingDeepLinkUri = null
                            }
                        }

                        override fun error(
                            errorCode: String,
                            errorMessage: String?,
                            errorDetails: Any?,
                        ) {}

                        override fun notImplemented() {}
                    },
                )
            }
        }
        return true
    }

    /**
     * Captures system share (`ACTION_SEND`, `ACTION_SEND_MULTIPLE`), selected-text
     * (`ACTION_PROCESS_TEXT`) and shortcut / tile / widget intents into shared payloads.
     * Returns `true` when [incomingIntent] was one of those actions.
     *
     * Cold start ([notifyFlutter] `false`) copies images synchronously and queues payloads for
     * `consumePendingSharedPayloads`; a warm start copies on a worker thread and dispatches live.
     */
    fun captureExternalIntent(incomingIntent: Intent?, notifyFlutter: Boolean): Boolean {
        val intent = incomingIntent ?: return false
        if (!AutoBillIntentCapture.isCapturable(intent)) return false
        if (!notifyFlutter) {
            for (payload in AutoBillIntentCapture.capture(appContext, intent)) {
                AutoBillNativeInbox.enqueueSharedPayload(appContext, payload)
            }
            return true
        }
        val snapshot = Intent(intent)
        AutoBillIntentCapture.clearHandled(intent)
        ioExecutor.execute {
            for (payload in AutoBillIntentCapture.capture(appContext, snapshot)) {
                deliverSharedPayload(payload)
            }
        }
        return true
    }

    private fun deliverSharedPayload(payload: Map<String, Any?>) {
        val listener = AutoBillNativeInbox.sharedListener
        if (listener != null && listener(payload)) return
        AutoBillNativeInbox.enqueueSharedPayload(appContext, payload)
    }

    /**
     * Invokes a Dart callback on the main thread. [onUnhandled] runs when Dart returns anything
     * but `true`, errors, or does not implement the callback. Returns `false` when detached.
     */
    private fun invokeFlutter(method: String, arguments: Any?, onUnhandled: () -> Unit): Boolean {
        val activeChannel = channel ?: return false
        mainHandler.post {
            activeChannel.invokeMethod(
                method,
                arguments,
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        if (result != true) onUnhandled()
                    }

                    override fun error(
                        errorCode: String,
                        errorMessage: String?,
                        errorDetails: Any?,
                    ) {
                        onUnhandled()
                    }

                    override fun notImplemented() {
                        onUnhandled()
                    }
                },
            )
        }
        return true
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "consumePendingDeepLink" -> {
                val uri = pendingDeepLinkUri
                pendingDeepLinkUri = null
                result.success(uri)
            }
            "updateWidgetSnapshot" -> {
                val snapshot = PersistedWidgetSnapshot(
                    bookName = call.argument<String>("bookName") ?: "日常账本",
                    periodLabel = call.argument<String>("periodLabel") ?: "本期",
                    currencySymbol = call.argument<String>("currencySymbol") ?: "¥",
                    expenseMinor = call.argument<String>("expenseMinor") ?: "0",
                    incomeMinor = call.argument<String>("incomeMinor") ?: "0",
                    balanceMinor = call.argument<String>("balanceMinor") ?: "0",
                    todayExpenseMinor = call.argument<String>("todayExpenseMinor") ?: "0",
                    budgetRemainingMinor = call.argument<String>("budgetRemainingMinor"),
                    expenseFormatted = call.argument<String>("expenseFormatted") ?: "0.00",
                    incomeFormatted = call.argument<String>("incomeFormatted") ?: "0.00",
                    balanceFormatted = call.argument<String>("balanceFormatted") ?: "0.00",
                    todayExpenseFormatted = call.argument<String>("todayExpenseFormatted") ?: "0.00",
                    budgetRemainingFormatted = call.argument<String>("budgetRemainingFormatted"),
                    updatedAtMs = (call.argument<Number>("updatedAtMs")?.toLong())
                        ?: System.currentTimeMillis(),
                    pendingDraftCount = (call.argument<Number>("pendingDraftCount")?.toInt() ?: 0)
                        .coerceAtLeast(0),
                )
                TallyWidgetStore.saveSnapshot(appContext, snapshot)
                val counts = TallyWidgetStore.updateAllWidgets(appContext)
                result.success(counts)
            }
            "getActiveWidgetCounts" -> {
                result.success(TallyWidgetStore.getActiveWidgetCounts(appContext))
            }
            "requestPinWidget" -> {
                val kind = call.argument<String>("kind").orEmpty()
                result.success(TallyWidgetStore.requestPinWidget(appContext, kind))
            }
            "getAccessibilityStatus" -> {
                result.success(
                    statusMap(AutoBillAccessibilityService.isServiceEnabled(appContext)),
                )
            }
            "openAccessibilitySettings" -> {
                openSettings(
                    Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS),
                    "无法打开系统无障碍设置页面",
                    result,
                )
            }
            "getNotificationListenerStatus" -> {
                result.success(
                    statusMap(AutoBillNotificationListenerService.isListenerEnabled(appContext)),
                )
            }
            "openNotificationListenerSettings" -> {
                openSettings(
                    Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS),
                    "无法打开系统通知使用权设置页面",
                    result,
                )
            }
            "getOverlayPermissionStatus" -> {
                val granted = Settings.canDrawOverlays(appContext)
                result.success(
                    mapOf(
                        "supported" to true,
                        "enabled" to granted,
                        "statusLabel" to if (granted) OVERLAY_GRANTED else OVERLAY_DENIED,
                    ),
                )
            }
            "openOverlaySettings" -> {
                openSettings(
                    Intent(
                        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        Uri.parse("package:${appContext.packageName}"),
                    ),
                    "无法打开系统悬浮窗权限设置页面",
                    result,
                )
            }
            "syncAndroidAutoBillConfig" -> {
                val categories = call.argument<List<Map<*, *>>>("categories").orEmpty()
                val assets = call.argument<List<Map<*, *>>>("assets").orEmpty()
                AutoBillNativeInbox.saveConfig(
                    context = appContext,
                    enableNotificationCapture =
                        call.argument<Boolean>("enableNotificationCapture") ?: true,
                    enableAccessibilityCapture =
                        call.argument<Boolean>("enableAccessibilityCapture") ?: true,
                    promptMode = call.argument<String>("promptMode")
                        ?: AutoBillNativeInbox.PROMPT_MODE_NOTIFICATION,
                    categories = categories,
                    assets = assets,
                )
                result.success(true)
            }
            "showAutoBillPrompt" -> showAutoBillPrompt(call, result)
            "consumeCapturedEvents" -> {
                val events = AutoBillNativeInbox.consumePersistedEvents(appContext)
                result.success(events.map { it.toMap() })
            }
            "consumePendingSharedPayloads" -> {
                result.success(AutoBillNativeInbox.consumeSharedPayloads(appContext))
            }
            "consumePendingPromptActions" -> {
                result.success(AutoBillNativeInbox.consumePromptActions(appContext))
            }
            "recognizeImageOffline" -> recognizeImageOffline(
                call.argument<ByteArray>("bytes"),
                call.argument<String>("fileName"),
                result,
            )
            else -> result.notImplemented()
        }
    }

    private fun statusMap(enabled: Boolean): Map<String, Any> = mapOf(
        "supported" to true,
        "enabled" to enabled,
        "statusLabel" to if (enabled) STATUS_ENABLED else STATUS_DISABLED,
    )

    private fun openSettings(intent: Intent, failureMessage: String, result: MethodChannel.Result) {
        if (activity == null) {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            val starter: Context = activity ?: appContext
            starter.startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("SETTINGS_UNAVAILABLE", e.message ?: failureMessage, null)
        }
    }

    private fun showAutoBillPrompt(call: MethodCall, result: MethodChannel.Result) {
        val request = AutoBillPromptRequest.fromCall(call)
        if (request.promptMode == AutoBillNativeInbox.PROMPT_MODE_SILENT) {
            result.success(true)
            return
        }
        val wantsOverlay = request.isDraft &&
            request.promptMode == AutoBillNativeInbox.PROMPT_MODE_OVERLAY &&
            Settings.canDrawOverlays(appContext)
        if (wantsOverlay && AutoBillOverlayManager.show(appContext, request)) {
            result.success(true)
            return
        }
        result.success(AutoBillPromptNotifier.postPrompt(appContext, request))
    }

    private fun recognizeImageOffline(
        bytes: ByteArray?,
        @Suppress("UNUSED_PARAMETER") fileName: String?,
        result: MethodChannel.Result,
    ) {
        if (bytes == null || bytes.isEmpty()) {
            result.error("OCR_FAILED", "图片数据为空，无法识别", null)
            return
        }
        ioExecutor.execute {
            val bitmap = decodeBitmap(bytes)
            if (bitmap == null) {
                mainHandler.post { result.error("OCR_FAILED", "无法解码图片，请换一张截图重试", null) }
                return@execute
            }
            try {
                val recognizer =
                    TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build())
                recognizer.process(InputImage.fromBitmap(bitmap, 0))
                    .addOnSuccessListener { visionText ->
                        bitmap.recycle()
                        recognizer.close()
                        runOnMain {
                            result.success(mapOf("supported" to true, "text" to visionText.text))
                        }
                    }
                    .addOnFailureListener { error ->
                        bitmap.recycle()
                        recognizer.close()
                        runOnMain {
                            result.error("OCR_FAILED", error.message ?: "本机离线识别失败", null)
                        }
                    }
            } catch (e: Exception) {
                bitmap.recycle()
                mainHandler.post {
                    result.error("OCR_FAILED", e.message ?: "本机离线识别失败", null)
                }
            }
        }
    }

    private fun runOnMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else mainHandler.post(block)
    }

    private fun decodeBitmap(bytes: ByteArray): Bitmap? {
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
            var sample = 1
            val longest = maxOf(bounds.outWidth, bounds.outHeight)
            while (longest / sample > MAX_OCR_SIDE_PX) sample *= 2
            val options = BitmapFactory.Options().apply { inSampleSize = sample }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
        } catch (_: Throwable) {
            null
        }
    }

    companion object {
        const val CHANNEL_NAME = "com.tallyisle/automation"
        const val STATUS_ENABLED = "已开启"
        const val STATUS_DISABLED = "未开启"
        const val OVERLAY_GRANTED = "已授权"
        const val OVERLAY_DENIED = "未授权"

        const val ACTION_SHORTCUT = "com.tallyisle.app.action.SHORTCUT"
        const val EXTRA_SHORTCUT_ACTION = "shortcut_action"
        const val EXTRA_SHORTCUT_SOURCE = "shortcut_source"
        const val SHORTCUT_NEW_RECORD = "new_record"
        const val SHORTCUT_SMART_BILL = "smart_bill"
        const val SHORTCUT_OCR_BILL = "ocr_bill"
        const val SHORTCUT_DRAFTS = "drafts"
        const val SOURCE_SHORTCUT = "shortcut"
        const val SOURCE_TILE = "tile"
        const val SOURCE_WIDGET = "widget"

        val SHORTCUT_ACTIONS: Set<String> = setOf(
            SHORTCUT_NEW_RECORD,
            SHORTCUT_SMART_BILL,
            SHORTCUT_OCR_BILL,
            SHORTCUT_DRAFTS,
        )

        private const val MAX_OCR_SIDE_PX = 4096
        private const val MAIN_ACTIVITY_CLASS = "com.tallyisle.app.MainActivity"

        private val ioExecutor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "tallyisle-automation-io").apply { isDaemon = true }
        }

        /** Explicit `MainActivity` intent carrying a `shortcut` payload for [captureExternalIntent]. */
        fun buildShortcutIntent(context: Context, shortcutAction: String, source: String): Intent =
            Intent(ACTION_SHORTCUT).apply {
                component = ComponentName(context.packageName, MAIN_ACTIVITY_CLASS)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra(EXTRA_SHORTCUT_ACTION, shortcutAction)
                putExtra(EXTRA_SHORTCUT_SOURCE, source)
            }
    }
}
