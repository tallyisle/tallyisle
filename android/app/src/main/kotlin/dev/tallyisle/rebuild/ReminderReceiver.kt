package dev.tallyisle.rebuild

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class ReminderAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != ReminderNativeScheduler.ACTION_FIRE_REMINDER) return
        val reminderId = intent.getIntExtra(ReminderNativeScheduler.EXTRA_REMINDER_ID, -1)
        if (reminderId < 0) return
        val scheduledAt = intent.getLongExtra(ReminderNativeScheduler.EXTRA_SCHEDULED_AT, 0L)
        ReminderNativeScheduler.onAlarmFired(context, reminderId, scheduledAt)
    }
}

class ReminderRescheduleReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        when (intent?.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            Intent.ACTION_TIME_CHANGED,
            Intent.ACTION_TIMEZONE_CHANGED,
            ACTION_EXACT_ALARM_PERMISSION_CHANGED,
            -> ReminderNativeScheduler.rescheduleFromPrefs(context)
        }
    }

    companion object {
        private const val ACTION_EXACT_ALARM_PERMISSION_CHANGED =
            "android.app.action.SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED"
    }
}
