package dev.tallyisle.rebuild

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Unified Android native MethodChannel bridge (`dev.tallyisle/automation`) for:
 *  - `F-033` `tallyisle://` & `yyjz://` external deep-link capture & live dispatch
 *  - `F-034` Desktop AppWidget snapshot sync & pin requests
 *  - `F-020` AccessibilityService permission check, settings jump, & captured event inbox
 */
class AutomationBridge(
    context: Context,
    private val activity: Activity? = context as? Activity,
) {
    private val appContext: Context = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var pendingDeepLinkUri: String? = null

    fun attach(messenger: BinaryMessenger) {
        val mc = MethodChannel(messenger, CHANNEL_NAME)
        mc.setMethodCallHandler(::handleMethodCall)
        channel = mc
        AutoBillAccessibilityService.liveListener = ::dispatchCapturedEventToFlutter
    }

    fun detach() {
        AutoBillAccessibilityService.liveListener = null
        channel?.setMethodCallHandler(null)
        channel = null
    }

    /**
     * Captures an incoming `tallyisle://` or `yyjz://` deep-link [Intent] from `onCreate`
     * or `onNewIntent`. Returns `true` when the intent carried a supported external URI.
     */
    fun captureIntent(incomingIntent: Intent?, notifyFlutter: Boolean = true): Boolean {
        val data: Uri = incomingIntent?.data ?: return false
        val scheme = data.scheme?.lowercase().orEmpty()
        if (scheme != "tallyisle" && scheme != "yyjz") return false
        val host = data.host?.lowercase().orEmpty()
        if (host == "reminder" || host == "reminder-open") return false

        val uriText = data.toString()
        incomingIntent.data = null
        pendingDeepLinkUri = uriText

        val activeChannel = channel
        if (notifyFlutter && activeChannel != null) {
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

    private fun dispatchCapturedEventToFlutter(event: CapturedAccessibilityEvent): Boolean {
        val activeChannel = channel ?: return false
        mainHandler.post {
            activeChannel.invokeMethod(
                "onCapturedEvent",
                event.toMap(),
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        if (result != true) {
                            AutoBillAccessibilityService.liveListener = null
                            AutoBillAccessibilityService.enqueueCapturedEvent(appContext, event)
                            if (channel != null) {
                                AutoBillAccessibilityService.liveListener =
                                    ::dispatchCapturedEventToFlutter
                            }
                        }
                    }

                    override fun error(
                        errorCode: String,
                        errorMessage: String?,
                        errorDetails: Any?,
                    ) {
                        AutoBillAccessibilityService.liveListener = null
                        AutoBillAccessibilityService.enqueueCapturedEvent(appContext, event)
                        if (channel != null) {
                            AutoBillAccessibilityService.liveListener =
                                ::dispatchCapturedEventToFlutter
                        }
                    }

                    override fun notImplemented() {}
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
                val enabled = AutoBillAccessibilityService.isServiceEnabled(appContext)
                result.success(
                    mapOf(
                        "supported" to true,
                        "enabled" to enabled,
                        "statusLabel" to if (enabled) STATUS_ENABLED else STATUS_DISABLED,
                    ),
                )
            }
            "openAccessibilitySettings" -> {
                val settingsIntent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                    if (activity == null) {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                }
                try {
                    val starter: Context = activity ?: appContext
                    starter.startActivity(settingsIntent)
                    result.success(true)
                } catch (e: Exception) {
                    result.error(
                        "SETTINGS_UNAVAILABLE",
                        e.message ?: "无法打开系统无障碍设置页面",
                        null,
                    )
                }
            }
            "consumeCapturedEvents" -> {
                val events = AutoBillAccessibilityService.consumePersistedEvents(appContext)
                result.success(events.map { it.toMap() })
            }
            else -> result.notImplemented()
        }
    }

    companion object {
        const val CHANNEL_NAME = "dev.tallyisle/automation"
        const val STATUS_ENABLED = "已开启"
        const val STATUS_DISABLED = "未开启"
    }
}
