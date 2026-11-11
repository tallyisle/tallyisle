package dev.tallyisle.rebuild

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var reminderChannel: MethodChannel? = null
    private var fileBridge: FileBridge? = null
    private var pendingLaunchRoute: String? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ReminderNativeScheduler.ensureNotificationChannel(this)
        captureLaunchRoute(intent, notifyFlutter = false)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureLaunchRoute(intent, notifyFlutter = true)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        val channel = MethodChannel(
            messenger,
            ReminderNativeScheduler.CHANNEL_NAME,
        )
        channel.setMethodCallHandler(::handleMethodCall)
        reminderChannel = channel

        val bridge = fileBridge ?: FileBridge(this).also { fileBridge = it }
        bridge.attach(messenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        reminderChannel?.setMethodCallHandler(null)
        reminderChannel = null
        fileBridge?.detach()
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        fileBridge?.shutdown()
        fileBridge = null
        super.onDestroy()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (fileBridge?.onActivityResult(requestCode, resultCode, data) == true) {
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "syncReminders" -> {
                val rawList = call.argument<List<Map<String, Any?>>>("reminders").orEmpty()
                val parsed = rawList.mapNotNull { map ->
                    val id = (map["id"] as? Number)?.toInt() ?: return@mapNotNull null
                    val hour = (map["hour"] as? Number)?.toInt() ?: 20
                    val minute = (map["minute"] as? Number)?.toInt() ?: 0
                    val title = (map["title"] as? String)
                        ?: ReminderNativeScheduler.DEFAULT_REMINDER_TIP
                    val body = (map["body"] as? String).orEmpty()
                    val route = (map["route"] as? String)
                        ?: ReminderNativeScheduler.DEFAULT_LAUNCH_ROUTE
                    PersistedReminder(
                        id = id,
                        hour = hour,
                        minute = minute,
                        title = title,
                        body = body,
                        route = route,
                    )
                }
                ReminderNativeScheduler.syncReminders(this, parsed)
                result.success(null)
            }
            "cancelReminder" -> {
                val id = call.argument<Number>("id")?.toInt()
                if (id != null) {
                    ReminderNativeScheduler.cancelReminder(this, id)
                }
                result.success(null)
            }
            "cancelAll" -> {
                ReminderNativeScheduler.cancelAll(this)
                result.success(null)
            }
            "areNotificationsEnabled" -> {
                result.success(ReminderNativeScheduler.areNotificationsEnabled(this))
            }
            "requestPermission" -> {
                handleRequestPermission(result)
            }
            "openNotificationSettings" -> {
                ReminderNativeScheduler.openNotificationSettings(this)
                result.success(null)
            }
            "consumePendingLaunchRoute" -> {
                val route = pendingLaunchRoute
                pendingLaunchRoute = null
                result.success(route)
            }
            else -> result.notImplemented()
        }
    }

    private fun handleRequestPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(ReminderNativeScheduler.areNotificationsEnabled(this))
            return
        }
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(ReminderNativeScheduler.areNotificationsEnabled(this))
            return
        }
        pendingPermissionResult?.success(false)
        pendingPermissionResult = result
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQUEST_CODE_POST_NOTIFICATIONS,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_CODE_POST_NOTIFICATIONS) {
            val callback = pendingPermissionResult
            pendingPermissionResult = null
            callback?.success(ReminderNativeScheduler.areNotificationsEnabled(this))
        }
    }

    private fun captureLaunchRoute(incomingIntent: Intent?, notifyFlutter: Boolean) {
        val route = incomingIntent?.getStringExtra(ReminderNativeScheduler.EXTRA_LAUNCH_ROUTE)
        if (route.isNullOrBlank()) return
        incomingIntent.removeExtra(ReminderNativeScheduler.EXTRA_LAUNCH_ROUTE)
        pendingLaunchRoute = route

        val channel = reminderChannel
        if (notifyFlutter && channel != null) {
            channel.invokeMethod(
                "onLaunchRoute",
                route,
                object : MethodChannel.Result {
                    override fun success(handled: Any?) {
                        if (handled == true) {
                            pendingLaunchRoute = null
                        }
                    }

                    override fun error(code: String, message: String?, details: Any?) {}

                    override fun notImplemented() {}
                },
            )
        }
    }

    companion object {
        private const val REQUEST_CODE_POST_NOTIFICATIONS = 4032
    }
}
