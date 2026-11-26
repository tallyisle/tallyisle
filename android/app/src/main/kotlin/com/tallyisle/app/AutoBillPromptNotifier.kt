package com.tallyisle.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import io.flutter.plugin.common.MethodCall

/** Parsed `showAutoBillPrompt` arguments. */
data class AutoBillPromptRequest(
    val promptKind: String,
    val promptMode: String,
    val draftId: Int?,
    val recordId: String?,
    val recordType: Int,
    val amountFormatted: String,
    val currencySymbol: String,
    val merchant: String,
    val categoryId: Int?,
    val categoryName: String?,
    val assetId: Int?,
    val assetName: String?,
) {
    val isDraft: Boolean get() = promptKind == AutoBillPromptNotifier.KIND_DRAFT

    companion object {
        fun fromCall(call: MethodCall): AutoBillPromptRequest = AutoBillPromptRequest(
            promptKind = call.argument<String>("promptKind") ?: AutoBillPromptNotifier.KIND_DRAFT,
            promptMode = call.argument<String>("promptMode")
                ?: AutoBillNativeInbox.PROMPT_MODE_NOTIFICATION,
            draftId = call.argument<Number>("draftId")?.toInt(),
            recordId = call.argument<String>("recordId"),
            recordType = call.argument<Number>("recordType")?.toInt() ?: 0,
            amountFormatted = call.argument<String>("amountFormatted") ?: "0.00",
            currencySymbol = call.argument<String>("currencySymbol") ?: "¥",
            merchant = call.argument<String>("merchant")?.trim().orEmpty(),
            categoryId = call.argument<Number>("categoryId")?.toInt(),
            categoryName = call.argument<String>("categoryName")?.trim()?.ifEmpty { null },
            assetId = call.argument<Number>("assetId")?.toInt(),
            assetName = call.argument<String>("assetName")?.trim()?.ifEmpty { null },
        )
    }
}

/**
 * Posts the actionable auto-bill notifications (channel `tallyisle_autobill_prompt`):
 *  - pending draft: `确认入账` / `修改` / `忽略`
 *  - auto-confirmed record: `修改` / `撤销`
 *  - lightweight cold-process fallback `识别到新支付账单 · 点击核对入账`
 */
object AutoBillPromptNotifier {
    const val CHANNEL_ID = "tallyisle_autobill_prompt"
    const val KIND_DRAFT = "draft"
    const val KIND_AUTO_CONFIRMED = "auto_confirmed"

    const val ACTION_CONFIRM_DRAFT = "confirm_draft"
    const val ACTION_IGNORE_DRAFT = "ignore_draft"
    const val ACTION_EDIT_DRAFT = "edit_draft"
    const val ACTION_EDIT_RECORD = "edit_record"
    const val ACTION_UNDO_RECORD = "undo_record"

    const val ROUTE_AUTO_BILL = "/automation/auto-bill"

    internal const val BROADCAST_ACTION = "com.tallyisle.app.action.AUTO_BILL_PROMPT_ACTION"
    internal const val EXTRA_PROMPT_ACTION = "com.tallyisle.app.extra.PROMPT_ACTION"
    internal const val EXTRA_DRAFT_ID = "com.tallyisle.app.extra.DRAFT_ID"
    internal const val EXTRA_RECORD_ID = "com.tallyisle.app.extra.RECORD_ID"
    internal const val EXTRA_NOTIFICATION_ID = "com.tallyisle.app.extra.NOTIFICATION_ID"

    private const val FALLBACK_NOTIFICATION_ID = 7301
    private const val FINISH_NOTIFICATION_ID = 7302

    fun ensureChannel(context: Context) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            context.getString(R.string.autobill_prompt_channel_name),
            NotificationManager.IMPORTANCE_HIGH,
        )
        channel.description = context.getString(R.string.autobill_prompt_channel_description)
        manager.createNotificationChannel(channel)
    }

    private fun notificationId(request: AutoBillPromptRequest): Int =
        if (request.isDraft) {
            "draft:${request.draftId}".hashCode()
        } else {
            "record:${request.recordId}".hashCode()
        }

    fun postPrompt(context: Context, request: AutoBillPromptRequest): Boolean {
        val appContext = context.applicationContext
        ensureChannel(appContext)
        val notifId = notificationId(request)
        val amountText = "${request.currencySymbol}${request.amountFormatted}"
        val builder = baseBuilder(appContext)
        if (request.isDraft) {
            val parts = listOfNotNull(
                request.merchant.ifEmpty { null },
                request.categoryName,
                request.assetName,
            )
            builder.setContentTitle("待确认记账 · $amountText")
                .setContentText(parts.joinToString(" · ").ifEmpty { "点击核对入账" })
                .setContentIntent(
                    launchPendingIntent(appContext, notifId, ROUTE_AUTO_BILL),
                )
                .addAction(
                    action(
                        appContext,
                        "确认入账",
                        broadcastPendingIntent(
                            appContext, notifId, ACTION_CONFIRM_DRAFT, request.draftId, null,
                        ),
                    ),
                )
                .addAction(
                    action(
                        appContext,
                        "修改",
                        launchPendingIntent(appContext, notifId + 1, ROUTE_AUTO_BILL),
                    ),
                )
                .addAction(
                    action(
                        appContext,
                        "忽略",
                        broadcastPendingIntent(
                            appContext, notifId, ACTION_IGNORE_DRAFT, request.draftId, null,
                        ),
                    ),
                )
        } else {
            val inner = listOfNotNull(request.categoryName, request.assetName)
                .joinToString(" · ")
            val merchant = request.merchant.ifEmpty { "智能识别账单" }
            val body = if (inner.isEmpty()) merchant else "$merchant（$inner）"
            val editRoute = "/record/${request.recordId.orEmpty()}/edit"
            builder.setContentTitle("已自动记账 · $amountText")
                .setContentText(body)
                .setContentIntent(launchPendingIntent(appContext, notifId, editRoute))
                .addAction(
                    action(
                        appContext,
                        "修改",
                        launchPendingIntent(appContext, notifId + 1, editRoute),
                    ),
                )
                .addAction(
                    action(
                        appContext,
                        "撤销",
                        broadcastPendingIntent(
                            appContext, notifId, ACTION_UNDO_RECORD, null, request.recordId,
                        ),
                    ),
                )
        }
        return notify(appContext, notifId, builder.build())
    }

    /** Cold-process fallback: a captured payment text is waiting in the native inbox. */
    fun postCaptureFallback(context: Context): Boolean {
        val appContext = context.applicationContext
        ensureChannel(appContext)
        val notification = baseBuilder(appContext)
            .setContentTitle("识别到新支付账单 · 点击核对入账")
            .setContentText("帐屿已在本机离线识别到一笔支付，点击进入核对。")
            .setContentIntent(
                launchPendingIntent(appContext, FALLBACK_NOTIFICATION_ID, ROUTE_AUTO_BILL),
            )
            .build()
        return notify(appContext, FALLBACK_NOTIFICATION_ID, notification)
    }

    fun cancel(context: Context, notificationId: Int) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(notificationId)
    }

    /**
     * Shared handler for notification buttons and the overlay card: cancels the notification,
     * dispatches [onPromptAction] live when a Flutter engine is attached, otherwise queues the
     * action and (for confirm / undo) opens TallyIsle so that it completes right away.
     */
    fun handlePromptAction(
        context: Context,
        action: String,
        draftId: Int?,
        recordId: String?,
        categoryId: Int? = null,
        assetId: Int? = null,
        remark: String? = null,
        notificationId: Int? = null,
    ) {
        val appContext = context.applicationContext
        if (notificationId != null) cancel(appContext, notificationId)
        val payload = LinkedHashMap<String, Any?>()
        payload["action"] = action
        payload["draftId"] = draftId
        payload["recordId"] = recordId
        payload["categoryId"] = categoryId
        payload["assetId"] = assetId
        payload["remark"] = remark
        payload["actionAtMs"] = System.currentTimeMillis()
        val live = AutoBillNativeInbox.dispatchPromptAction(appContext, payload)
        if (live) return
        if (action == ACTION_CONFIRM_DRAFT || action == ACTION_UNDO_RECORD) {
            launchApp(appContext)
        }
    }

    private fun launchApp(context: Context) {
        try {
            val intent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            context.startActivity(intent)
        } catch (_: Exception) {
            // Falls through to the follow-up notification below.
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Android 12+ blocks activity launches from notification trampolines; keep the queued
            // action honest by asking the user to open TallyIsle to finish.
            ensureChannel(context)
            val notification = baseBuilder(context)
                .setContentTitle("已记录你的操作 · 点击完成")
                .setContentText("打开帐屿后会立即完成刚才的确认 / 撤销。")
                .setContentIntent(
                    launchPendingIntent(context, FINISH_NOTIFICATION_ID, ROUTE_AUTO_BILL),
                )
                .build()
            notify(context, FINISH_NOTIFICATION_ID, notification)
        }
    }

    private fun baseBuilder(context: Context): Notification.Builder =
        Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_tile_quick_bill)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_STATUS)
            .setVisibility(Notification.VISIBILITY_PRIVATE)

    private fun action(
        context: Context,
        title: String,
        pendingIntent: PendingIntent,
    ): Notification.Action = Notification.Action.Builder(
        Icon.createWithResource(context, R.drawable.ic_tile_quick_bill),
        title,
        pendingIntent,
    ).build()

    private fun notify(context: Context, id: Int, notification: Notification): Boolean {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        return try {
            manager.notify(id, notification)
            true
        } catch (_: SecurityException) {
            false
        }
    }

    private fun launchPendingIntent(context: Context, requestCode: Int, route: String): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(ReminderNativeScheduler.EXTRA_LAUNCH_ROUTE, route)
        }
        return PendingIntent.getActivity(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun broadcastPendingIntent(
        context: Context,
        notificationId: Int,
        action: String,
        draftId: Int?,
        recordId: String?,
    ): PendingIntent {
        val intent = Intent(context, AutoBillActionReceiver::class.java).apply {
            this.action = BROADCAST_ACTION
            putExtra(EXTRA_PROMPT_ACTION, action)
            putExtra(EXTRA_NOTIFICATION_ID, notificationId)
            if (draftId != null) putExtra(EXTRA_DRAFT_ID, draftId)
            if (recordId != null) putExtra(EXTRA_RECORD_ID, recordId)
        }
        return PendingIntent.getBroadcast(
            context,
            notificationId * 31 + action.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}

/** Receives `确认入账` / `忽略` / `撤销` taps from the prompt notifications. */
class AutoBillActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.getStringExtra(AutoBillPromptNotifier.EXTRA_PROMPT_ACTION) ?: return
        val draftId = if (intent.hasExtra(AutoBillPromptNotifier.EXTRA_DRAFT_ID)) {
            intent.getIntExtra(AutoBillPromptNotifier.EXTRA_DRAFT_ID, -1).takeIf { it >= 0 }
        } else {
            null
        }
        val recordId = intent.getStringExtra(AutoBillPromptNotifier.EXTRA_RECORD_ID)
        val notificationId = if (intent.hasExtra(AutoBillPromptNotifier.EXTRA_NOTIFICATION_ID)) {
            intent.getIntExtra(AutoBillPromptNotifier.EXTRA_NOTIFICATION_ID, 0)
        } else {
            null
        }
        AutoBillPromptNotifier.handlePromptAction(
            context = context,
            action = action,
            draftId = draftId,
            recordId = recordId,
            notificationId = notificationId,
        )
    }
}
