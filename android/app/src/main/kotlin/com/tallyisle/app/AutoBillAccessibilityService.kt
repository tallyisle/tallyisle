package com.tallyisle.app

import android.accessibilityservice.AccessibilityService
import android.content.ComponentName
import android.content.Context
import android.provider.Settings
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Local-only Android AccessibilityService for capturing payment confirmation / notification
 * texts from supported payment, bank & SMS apps and queueing them for draft review (`F-020`).
 *
 * Optional enhancement channel (`channel = "accessibility"`) next to
 * [AutoBillNotificationListenerService]; both feed the shared [AutoBillNativeInbox] which
 * applies the business switch and cross-channel 15 second de-duplication.
 *
 * Never uploads screen data anywhere; all parsing and confirmation happen locally in TallyIsle.
 */
class AutoBillAccessibilityService : AccessibilityService() {
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        val pkg = event.packageName?.toString()?.trim().orEmpty()
        if (pkg.isEmpty() || pkg !in SUPPORTED_PACKAGES) return
        if (!AutoBillNativeInbox.loadConfig(applicationContext).enableAccessibilityCapture) return

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
        if (!AutoBillNativeInbox.looksLikePaymentText(joined)) return

        AutoBillNativeInbox.ingestCaptured(
            applicationContext,
            CapturedPaymentEvent(
                packageName = pkg,
                rawText = joined,
                capturedAtMs = System.currentTimeMillis(),
                channel = AutoBillNativeInbox.CHANNEL_ACCESSIBILITY,
            ),
        )
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
        private const val MAX_COLLECTED_LINES = 40
        private const val MAX_TREE_DEPTH = 12
        private const val MAX_SINGLE_LINE_CHARS = 200

        /** Payment apps + major bank apps + SMS apps (identical to the notification channel). */
        val SUPPORTED_PACKAGES: Set<String> = AutoBillNativeInbox.ALL_SUPPORTED_PACKAGES

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
    }
}
