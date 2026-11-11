package dev.tallyisle.rebuild

import android.Manifest
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar

data class PersistedReminder(
    val id: Int,
    val hour: Int,
    val minute: Int,
    val title: String,
    val body: String,
    val route: String,
)

object ReminderNativeScheduler {
    const val CHANNEL_NAME = "dev.tallyisle/reminders"
    const val NOTIFICATION_CHANNEL_ID = "bookkeeping_reminder"
    const val NOTIFICATION_CHANNEL_NAME = "记账提醒"
    const val DEFAULT_REMINDER_TIP = "是时候来记账啦！"
    const val DEFAULT_LAUNCH_ROUTE = "/record/new"

    const val ACTION_FIRE_REMINDER = "dev.tallyisle.rebuild.ACTION_FIRE_REMINDER"
    const val EXTRA_REMINDER_ID = "dev.tallyisle.rebuild.extra.REMINDER_ID"
    const val EXTRA_SCHEDULED_AT = "dev.tallyisle.rebuild.extra.SCHEDULED_AT"
    const val EXTRA_LAUNCH_ROUTE = "dev.tallyisle.rebuild.extra.LAUNCH_ROUTE"

    private const val PREFS_NAME = "tallyisle_reminders"
    private const val KEY_REMINDERS_JSON = "reminders_json"

    fun ensureNotificationChannel(context: Context) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            NOTIFICATION_CHANNEL_NAME,
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "每日定时记账提醒"
        }
        manager.createNotificationChannel(channel)
    }

    fun syncReminders(context: Context, reminders: List<PersistedReminder>) {
        val appContext = context.applicationContext
        ensureNotificationChannel(appContext)
        val alarmManager = appContext.getSystemService(Context.ALARM_SERVICE) as AlarmManager

        val previous = loadPersistedReminders(appContext)
        val incomingIds = reminders.map { it.id }.toSet()
        for (old in previous) {
            if (old.id !in incomingIds) {
                cancelAlarmOnly(appContext, alarmManager, old.id)
            }
        }

        savePersistedReminders(appContext, reminders)
        val now = System.currentTimeMillis()
        for (reminder in reminders) {
            scheduleSingleAlarm(appContext, alarmManager, reminder, now)
        }
    }

    fun cancelReminder(context: Context, id: Int) {
        val appContext = context.applicationContext
        val alarmManager = appContext.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        cancelAlarmOnly(appContext, alarmManager, id)
        val remaining = loadPersistedReminders(appContext).filter { it.id != id }
        savePersistedReminders(appContext, remaining)
    }

    fun cancelAll(context: Context) {
        val appContext = context.applicationContext
        val alarmManager = appContext.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val previous = loadPersistedReminders(appContext)
        for (item in previous) {
            cancelAlarmOnly(appContext, alarmManager, item.id)
        }
        savePersistedReminders(appContext, emptyList())
    }

    fun rescheduleFromPrefs(context: Context) {
        val appContext = context.applicationContext
        ensureNotificationChannel(appContext)
        val reminders = loadPersistedReminders(appContext)
        if (reminders.isEmpty()) return
        val alarmManager = appContext.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val now = System.currentTimeMillis()
        for (reminder in reminders) {
            scheduleSingleAlarm(appContext, alarmManager, reminder, now)
        }
    }

    fun onAlarmFired(context: Context, reminderId: Int, scheduledAtMillis: Long) {
        val appContext = context.applicationContext
        val alarmManager = appContext.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val reminder = loadPersistedReminders(appContext).firstOrNull { it.id == reminderId }
        if (reminder == null) {
            cancelAlarmOnly(appContext, alarmManager, reminderId)
            return
        }

        val referenceNow = maxOf(System.currentTimeMillis(), scheduledAtMillis)
        scheduleSingleAlarm(appContext, alarmManager, reminder, referenceNow)

        ensureNotificationChannel(appContext)
        if (!areNotificationsEnabled(appContext)) return

        val route = reminder.route.ifBlank { DEFAULT_LAUNCH_ROUTE }
        val tapIntent = Intent(appContext, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP
            data = Uri.parse("tallyisle://reminder-open/${reminder.id}")
            putExtra(EXTRA_LAUNCH_ROUTE, route)
        }
        val contentIntent = PendingIntent.getActivity(
            appContext,
            reminder.id,
            tapIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val smallIcon = appContext.applicationInfo.icon.takeIf { it != 0 }
            ?: android.R.drawable.ic_popup_reminder
        val title = reminder.title.ifBlank { DEFAULT_REMINDER_TIP }
        val body = reminder.body.ifBlank { "点击记一笔" }

        val notification = Notification.Builder(appContext, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(smallIcon)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(contentIntent)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_REMINDER)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .build()

        val notificationManager =
            appContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        try {
            notificationManager.notify(reminder.id, notification)
        } catch (_: SecurityException) {
            // Permission may be revoked concurrently on Android 13+.
        }
    }

    fun areNotificationsEnabled(context: Context): Boolean {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (!manager.areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                PackageManager.PERMISSION_GRANTED
            ) {
                return false
            }
        }
        val channel = manager.getNotificationChannel(NOTIFICATION_CHANNEL_ID)
        if (channel != null && channel.importance == NotificationManager.IMPORTANCE_NONE) {
            return false
        }
        return true
    }

    fun openNotificationSettings(context: Context) {
        val settingsIntent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
            putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            context.startActivity(settingsIntent)
        } catch (_: Exception) {
            val fallback = Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", context.packageName, null),
            ).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(fallback)
        }
    }

    fun computeNextTriggerMillis(
        hour: Int,
        minute: Int,
        referenceNowMillis: Long = System.currentTimeMillis(),
    ): Long {
        val cal = Calendar.getInstance().apply {
            timeInMillis = referenceNowMillis
            set(Calendar.HOUR_OF_DAY, hour.coerceIn(0, 23))
            set(Calendar.MINUTE, minute.coerceIn(0, 59))
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        if (cal.timeInMillis <= referenceNowMillis) {
            cal.add(Calendar.DAY_OF_YEAR, 1)
        }
        return cal.timeInMillis
    }

    private fun scheduleSingleAlarm(
        context: Context,
        alarmManager: AlarmManager,
        reminder: PersistedReminder,
        referenceNowMillis: Long,
    ) {
        val triggerAt = computeNextTriggerMillis(reminder.hour, reminder.minute, referenceNowMillis)
        val alarmIntent = buildAlarmIntent(context, reminder.id).apply {
            putExtra(EXTRA_REMINDER_ID, reminder.id)
            putExtra(EXTRA_SCHEDULED_AT, triggerAt)
        }
        val pendingIntent = PendingIntent.getBroadcast(
            context,
            reminder.id,
            alarmIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (alarmManager.canScheduleExactAlarms()) {
                try {
                    alarmManager.setExactAndAllowWhileIdle(
                        AlarmManager.RTC_WAKEUP,
                        triggerAt,
                        pendingIntent,
                    )
                    return
                } catch (_: SecurityException) {
                    // Fall through to inexact scheduling when exact alarm permission is absent.
                }
            }
            alarmManager.setAndAllowWhileIdle(
                AlarmManager.RTC_WAKEUP,
                triggerAt,
                pendingIntent,
            )
        } else {
            try {
                alarmManager.setExactAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    triggerAt,
                    pendingIntent,
                )
            } catch (_: SecurityException) {
                alarmManager.setAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    triggerAt,
                    pendingIntent,
                )
            }
        }
    }

    private fun cancelAlarmOnly(context: Context, alarmManager: AlarmManager, id: Int) {
        val existing = PendingIntent.getBroadcast(
            context,
            id,
            buildAlarmIntent(context, id),
            PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE,
        )
        if (existing != null) {
            alarmManager.cancel(existing)
            existing.cancel()
        }
    }

    private fun buildAlarmIntent(context: Context, id: Int): Intent =
        Intent(context, ReminderAlarmReceiver::class.java).apply {
            action = ACTION_FIRE_REMINDER
            data = Uri.parse("tallyisle://reminder/$id")
        }

    private fun loadPersistedReminders(context: Context): List<PersistedReminder> {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val raw = prefs.getString(KEY_REMINDERS_JSON, null) ?: return emptyList()
        return try {
            val arr = JSONArray(raw)
            buildList(arr.length()) {
                for (i in 0 until arr.length()) {
                    val obj = arr.optJSONObject(i) ?: continue
                    val id = obj.optInt("id", -1)
                    if (id < 0) continue
                    add(
                        PersistedReminder(
                            id = id,
                            hour = obj.optInt("hour", 20).coerceIn(0, 23),
                            minute = obj.optInt("minute", 0).coerceIn(0, 59),
                            title = obj.optString("title", DEFAULT_REMINDER_TIP),
                            body = obj.optString("body", ""),
                            route = obj.optString("route", DEFAULT_LAUNCH_ROUTE),
                        ),
                    )
                }
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun savePersistedReminders(context: Context, reminders: List<PersistedReminder>) {
        val arr = JSONArray()
        for (r in reminders) {
            val obj = JSONObject().apply {
                put("id", r.id)
                put("hour", r.hour)
                put("minute", r.minute)
                put("title", r.title)
                put("body", r.body)
                put("route", r.route)
            }
            arr.put(obj)
        }
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_REMINDERS_JSON, arr.toString())
            .commit()
    }
}
