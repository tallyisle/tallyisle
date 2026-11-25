package dev.tallyisle.rebuild

import android.app.Notification
import android.content.ComponentName
import android.content.Context
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/**
 * Primary (recommended) background capture channel: reads the visible text of payment, bank and
 * SMS app notifications (`channel = "notification"`) strictly on this device and forwards it to
 * the shared [AutoBillNativeInbox]. Nothing is uploaded.
 */
class AutoBillNotificationListenerService : NotificationListenerService() {
    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        if (sbn == null) return
        val pkg = sbn.packageName?.trim().orEmpty()
        if (pkg.isEmpty() || pkg == packageName) return
        if (pkg !in SUPPORTED_PACKAGES) return
        val notification = sbn.notification ?: return
        if (sbn.isOngoing) return
        if (notification.flags and (
                Notification.FLAG_ONGOING_EVENT or Notification.FLAG_FOREGROUND_SERVICE
            ) != 0
        ) {
            return
        }
        if (!AutoBillNativeInbox.loadConfig(applicationContext).enableNotificationCapture) return

        val extras = notification.extras ?: return
        val lines = LinkedHashSet<String>()
        for (key in listOf(
            Notification.EXTRA_TITLE,
            Notification.EXTRA_TEXT,
            Notification.EXTRA_BIG_TEXT,
            Notification.EXTRA_SUB_TEXT,
        )) {
            val value = extras.getCharSequence(key)?.toString()?.trim().orEmpty()
            if (value.isNotEmpty()) lines.add(value)
        }
        if (lines.isEmpty()) return

        AutoBillNativeInbox.ingestCaptured(
            applicationContext,
            CapturedPaymentEvent(
                packageName = pkg,
                rawText = lines.joinToString("\n"),
                capturedAtMs = System.currentTimeMillis(),
                channel = AutoBillNativeInbox.CHANNEL_NOTIFICATION,
            ),
        )
    }

    companion object {
        val SUPPORTED_PACKAGES: Set<String> = AutoBillNativeInbox.ALL_SUPPORTED_PACKAGES

        fun isListenerEnabled(context: Context): Boolean {
            val appContext = context.applicationContext
            val raw = try {
                Settings.Secure.getString(
                    appContext.contentResolver,
                    "enabled_notification_listeners",
                )
            } catch (_: Exception) {
                null
            } ?: return false
            val expected = ComponentName(
                appContext.packageName,
                AutoBillNotificationListenerService::class.java.name,
            )
            for (token in raw.split(':')) {
                val trimmed = token.trim()
                if (trimmed.isEmpty()) continue
                if (ComponentName.unflattenFromString(trimmed) == expected) return true
            }
            return false
        }
    }
}
