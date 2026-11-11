package dev.tallyisle.rebuild

import android.app.Activity
import android.app.KeyguardManager
import android.content.DialogInterface
import android.content.pm.PackageManager
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android native bridge for app-lock biometric authentication (`F-024`, `ADR-008`).
 *
 * Uses ONLY platform SDK classes (`android.hardware.biometrics.BiometricPrompt`,
 * `BiometricManager`, and `KeyguardManager`) with zero external Gradle dependencies.
 */
class BiometricBridge(private val activity: Activity) {
    private var channel: MethodChannel? = null
    private var activeSession: AuthSession? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val mainExecutor = Executor { command -> mainHandler.post(command) }

    private class AuthSession(
        val signal: CancellationSignal,
        val result: MethodChannel.Result,
    ) {
        private val finished = AtomicBoolean(false)

        fun complete(outcome: String, message: String): Boolean {
            if (!finished.compareAndSet(false, true)) return false
            result.success(
                mapOf(
                    "outcome" to outcome,
                    "message" to message,
                ),
            )
            return true
        }
    }

    fun attach(messenger: BinaryMessenger) {
        val methodChannel = MethodChannel(messenger, CHANNEL_NAME)
        methodChannel.setMethodCallHandler(::handleMethodCall)
        channel = methodChannel
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
        cancelCurrentSession("已取消生物识别验证")
    }

    fun shutdown() {
        detach()
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "checkAvailability" -> result.success(queryAvailability())
            "authenticate" -> handleAuthenticate(call, result)
            "cancelAuthentication" -> {
                cancelCurrentSession("已取消生物识别验证")
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun queryAvailability(): Map<String, Any> {
        val keyguard = activity.getSystemService(KeyguardManager::class.java)
        val deviceSecure = keyguard?.isDeviceSecure == true

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            return mapOf(
                "status" to STATUS_UNSUPPORTED,
                "reason" to "当前 Android 版本低于 9.0，请使用数字密码解锁",
                "deviceSecure" to deviceSecure,
            )
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val manager = activity.getSystemService(BiometricManager::class.java)
                ?: return mapOf(
                    "status" to STATUS_NO_HARDWARE,
                    "reason" to "设备未提供生物识别服务",
                    "deviceSecure" to deviceSecure,
                )
            val code = manager.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_WEAK)
            return when (code) {
                BiometricManager.BIOMETRIC_SUCCESS -> mapOf(
                    "status" to STATUS_AVAILABLE,
                    "reason" to "可使用系统指纹或面容解锁",
                    "deviceSecure" to deviceSecure,
                )
                BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> mapOf(
                    "status" to STATUS_NOT_ENROLLED,
                    "reason" to "系统尚未录入指纹或面容，请先在系统设置中录入",
                    "deviceSecure" to deviceSecure,
                )
                BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE -> mapOf(
                    "status" to STATUS_NO_HARDWARE,
                    "reason" to "当前设备无指纹或面容识别硬件",
                    "deviceSecure" to deviceSecure,
                )
                BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE,
                BiometricManager.BIOMETRIC_ERROR_SECURITY_UPDATE_REQUIRED -> mapOf(
                    "status" to STATUS_TEMPORARILY_UNAVAILABLE,
                    "reason" to "生物识别硬件暂不可用，请使用数字密码",
                    "deviceSecure" to deviceSecure,
                )
                else -> mapOf(
                    "status" to STATUS_UNSUPPORTED,
                    "reason" to "当前设备环境不支持生物识别解锁",
                    "deviceSecure" to deviceSecure,
                )
            }
        }

        val pm = activity.packageManager
        val hasHardware = pm.hasSystemFeature(PackageManager.FEATURE_FINGERPRINT)
        if (!hasHardware) {
            return mapOf(
                "status" to STATUS_NO_HARDWARE,
                "reason" to "当前设备无指纹识别硬件",
                "deviceSecure" to deviceSecure,
            )
        }
        if (!deviceSecure) {
            return mapOf(
                "status" to STATUS_NOT_ENROLLED,
                "reason" to "系统尚未设置锁屏与指纹凭据",
                "deviceSecure" to false,
            )
        }
        return mapOf(
            "status" to STATUS_AVAILABLE,
            "reason" to "可使用系统生物识别解锁",
            "deviceSecure" to true,
        )
    }

    private fun handleAuthenticate(call: MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            result.success(
                mapOf(
                    "outcome" to OUTCOME_UNSUPPORTED,
                    "message" to "当前系统版本不支持生物识别，请使用数字密码",
                ),
            )
            return
        }

        val availability = queryAvailability()
        if (availability["status"] != STATUS_AVAILABLE) {
            result.success(
                mapOf(
                    "outcome" to OUTCOME_UNAVAILABLE,
                    "message" to (availability["reason"] as? String ?: "生物识别当前不可用"),
                ),
            )
            return
        }

        cancelCurrentSession("已开启新的生物识别请求")

        val title = call.argument<String>("title")
            ?.takeIf { it.isNotBlank() }
            ?: "验证身份以解锁帐屿"
        val subtitle = call.argument<String>("subtitle")?.takeIf { it.isNotBlank() }
        val negativeText = call.argument<String>("negativeButtonText")
            ?.takeIf { it.isNotBlank() }
            ?: "使用数字密码"

        val signal = CancellationSignal()
        val session = AuthSession(signal = signal, result = result)
        activeSession = session

        try {
            val builder = BiometricPrompt.Builder(activity)
                .setTitle(title)
                .setConfirmationRequired(false)
            if (subtitle != null) {
                builder.setSubtitle(subtitle)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                builder.setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_WEAK)
            }
            builder.setNegativeButton(
                negativeText,
                mainExecutor,
                DialogInterface.OnClickListener { _, _ ->
                    finishSession(session, OUTCOME_CANCELLED, "已切换为数字密码验证")
                },
            )
            val prompt = builder.build()
            prompt.authenticate(
                signal,
                mainExecutor,
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(
                        authResult: BiometricPrompt.AuthenticationResult,
                    ) {
                        finishSession(session, OUTCOME_AUTHENTICATED, "生物识别验证通过")
                    }

                    override fun onAuthenticationError(
                        errorCode: Int,
                        errString: CharSequence?,
                    ) {
                        val msg = errString?.toString()?.takeIf { it.isNotBlank() }
                        when (errorCode) {
                            BiometricPrompt.BIOMETRIC_ERROR_USER_CANCELED,
                            BiometricPrompt.BIOMETRIC_ERROR_CANCELED -> {
                                finishSession(
                                    session,
                                    OUTCOME_CANCELLED,
                                    msg ?: "已取消生物识别，请输入数字密码",
                                )
                            }
                            BiometricPrompt.BIOMETRIC_ERROR_LOCKOUT,
                            BiometricPrompt.BIOMETRIC_ERROR_LOCKOUT_PERMANENT -> {
                                finishSession(
                                    session,
                                    OUTCOME_LOCKOUT,
                                    msg ?: "生物识别尝试次数过多，请使用数字密码解锁",
                                )
                            }
                            BiometricPrompt.BIOMETRIC_ERROR_NO_BIOMETRICS,
                            BiometricPrompt.BIOMETRIC_ERROR_HW_NOT_PRESENT,
                            BiometricPrompt.BIOMETRIC_ERROR_HW_UNAVAILABLE -> {
                                finishSession(
                                    session,
                                    OUTCOME_UNAVAILABLE,
                                    msg ?: "生物识别当前不可用，请使用数字密码",
                                )
                            }
                            else -> {
                                finishSession(
                                    session,
                                    OUTCOME_FAILED,
                                    msg ?: "生物识别未通过，请使用数字密码",
                                )
                            }
                        }
                    }
                },
            )
        } catch (e: Exception) {
            finishSession(
                session,
                OUTCOME_UNAVAILABLE,
                e.message ?: "无法调起系统生物识别，请使用数字密码",
            )
        }
    }

    private fun finishSession(session: AuthSession, outcome: String, message: String) {
        mainHandler.post {
            if (activeSession === session) {
                activeSession = null
            }
            session.complete(outcome, message)
        }
    }

    private fun cancelCurrentSession(reason: String) {
        val existing = activeSession ?: return
        activeSession = null
        if (!existing.signal.isCanceled) {
            try {
                existing.signal.cancel()
            } catch (_: Exception) {
                // Ignore cancellation race if prompt already dismissed.
            }
        }
        mainHandler.post {
            existing.complete(OUTCOME_CANCELLED, reason)
        }
    }

    companion object {
        const val CHANNEL_NAME = "dev.tallyisle/biometrics"

        private const val STATUS_AVAILABLE = "available"
        private const val STATUS_NOT_ENROLLED = "notEnrolled"
        private const val STATUS_NO_HARDWARE = "noHardware"
        private const val STATUS_TEMPORARILY_UNAVAILABLE = "temporarilyUnavailable"
        private const val STATUS_UNSUPPORTED = "unsupported"

        private const val OUTCOME_AUTHENTICATED = "authenticated"
        private const val OUTCOME_CANCELLED = "cancelled"
        private const val OUTCOME_LOCKOUT = "lockout"
        private const val OUTCOME_UNAVAILABLE = "unavailable"
        private const val OUTCOME_UNSUPPORTED = "unsupported"
        private const val OUTCOME_FAILED = "failed"
    }
}
