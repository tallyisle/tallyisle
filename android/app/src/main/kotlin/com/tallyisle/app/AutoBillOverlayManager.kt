package com.tallyisle.app

import android.content.Context
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.EditText
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.TextView

/**
 * Cross-app bottom-sheet bookkeeping card (`TYPE_APPLICATION_OVERLAY`), shown only when the user
 * picked the overlay prompt mode and granted the system "draw over other apps" permission.
 * Pure Kotlin views, Light / Dark aware, dismissed by back key or tapping outside.
 */
object AutoBillOverlayManager {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var currentView: View? = null
    private var currentWindowManager: WindowManager? = null

    /** Shows the card; returns `false` when the window could not be added. */
    fun show(context: Context, request: AutoBillPromptRequest): Boolean {
        val appContext = context.applicationContext
        var shown = false
        val latch = java.util.concurrent.CountDownLatch(1)
        val task = Runnable {
            shown = try {
                showOnMain(appContext, request)
            } catch (_: Exception) {
                false
            }
            latch.countDown()
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            task.run()
        } else {
            mainHandler.post(task)
            latch.await(2, java.util.concurrent.TimeUnit.SECONDS)
        }
        return shown
    }

    fun dismiss() {
        val task = Runnable { dismissOnMain() }
        if (Looper.myLooper() == Looper.getMainLooper()) task.run() else mainHandler.post(task)
    }

    private fun dismissOnMain() {
        val view = currentView
        val wm = currentWindowManager
        currentView = null
        currentWindowManager = null
        if (view != null && wm != null) {
            try {
                wm.removeView(view)
            } catch (_: Exception) {
                // Already detached.
            }
        }
    }

    private class OverlayRoot(context: Context, private val onDismiss: () -> Unit) :
        LinearLayout(context) {
        override fun dispatchKeyEvent(event: KeyEvent): Boolean {
            if (event.keyCode == KeyEvent.KEYCODE_BACK) {
                if (event.action == KeyEvent.ACTION_UP) onDismiss()
                return true
            }
            return super.dispatchKeyEvent(event)
        }

        override fun onTouchEvent(event: MotionEvent): Boolean {
            if (event.action == MotionEvent.ACTION_OUTSIDE) {
                onDismiss()
                return true
            }
            return super.onTouchEvent(event)
        }
    }

    private class Palette(night: Boolean) {
        val sheet = if (night) Color.parseColor("#1E293B") else Color.WHITE
        val text = if (night) Color.parseColor("#F1F5F9") else Color.parseColor("#0F172A")
        val subtext = if (night) Color.parseColor("#94A3B8") else Color.parseColor("#64748B")
        val chip = if (night) Color.parseColor("#334155") else Color.parseColor("#E2E8F0")
        val chipText = if (night) Color.parseColor("#E2E8F0") else Color.parseColor("#334155")
        val field = if (night) Color.parseColor("#0F172A") else Color.parseColor("#F1F5F9")
        val accent = if (night) Color.parseColor("#14B8A6") else Color.parseColor("#0F766E")
        val onAccent = if (night) Color.parseColor("#042F2E") else Color.WHITE
    }

    @Suppress("DEPRECATION")
    private fun showOnMain(context: Context, request: AutoBillPromptRequest): Boolean {
        dismissOnMain()
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val night = (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
            Configuration.UI_MODE_NIGHT_YES
        val palette = Palette(night)
        val config = AutoBillNativeInbox.loadConfig(context)

        fun dp(value: Int): Int = TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            value.toFloat(),
            context.resources.displayMetrics,
        ).toInt()

        fun pill(color: Int, radiusDp: Int): GradientDrawable = GradientDrawable().apply {
            setColor(color)
            cornerRadius = dp(radiusDp).toFloat()
        }

        val root = OverlayRoot(context) { dismissOnMain() }
        root.orientation = LinearLayout.VERTICAL
        root.setPadding(dp(20), dp(16), dp(20), dp(20))
        root.background = GradientDrawable().apply {
            setColor(palette.sheet)
            val r = dp(24).toFloat()
            cornerRadii = floatArrayOf(r, r, r, r, 0f, 0f, 0f, 0f)
        }

        // Header: title + close button.
        val header = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val title = TextView(context).apply {
            text = "待确认记账"
            setTextColor(palette.subtext)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            setTypeface(typeface, Typeface.BOLD)
        }
        header.addView(title, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        val close = TextView(context).apply {
            text = "✕"
            gravity = Gravity.CENTER
            setTextColor(palette.subtext)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
            setPadding(dp(10), dp(4), dp(10), dp(4))
            setOnClickListener { dismissOnMain() }
        }
        header.addView(close)
        root.addView(header)

        // Amount.
        root.addView(
            TextView(context).apply {
                text = "${request.currencySymbol}${request.amountFormatted}"
                setTextColor(palette.text)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 32f)
                setTypeface(typeface, Typeface.BOLD)
                setPadding(0, dp(4), 0, dp(8))
            },
        )

        // Editable merchant / remark.
        val remarkField = EditText(context).apply {
            setText(request.merchant)
            hint = "商户 / 备注"
            setTextColor(palette.text)
            setHintTextColor(palette.subtext)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            inputType = InputType.TYPE_CLASS_TEXT
            maxLines = 1
            setSingleLine(true)
            background = pill(palette.field, 12)
            setPadding(dp(14), dp(10), dp(14), dp(10))
        }
        root.addView(
            remarkField,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )

        // Category / asset chip rows.
        var selectedCategoryId: Int? = request.categoryId
        var selectedAssetId: Int? = request.assetId

        fun chipRow(
            label: String,
            options: List<PromptOption>,
            initial: Int?,
            onSelected: (Int) -> Unit,
        ) {
            if (options.isEmpty()) return
            root.addView(
                TextView(context).apply {
                    text = label
                    setTextColor(palette.subtext)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                    setPadding(0, dp(12), 0, dp(6))
                },
            )
            val row = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL }
            val chips = LinkedHashMap<Int, TextView>()
            fun paint(selected: Int?) {
                for ((id, chip) in chips) {
                    val on = id == selected
                    chip.background = pill(if (on) palette.accent else palette.chip, 18)
                    chip.setTextColor(if (on) palette.onAccent else palette.chipText)
                }
            }
            for (option in options) {
                val chip = TextView(context).apply {
                    text = option.name
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                    setPadding(dp(14), dp(7), dp(14), dp(7))
                    maxLines = 1
                    setOnClickListener {
                        onSelected(option.id)
                        paint(option.id)
                    }
                }
                chips[option.id] = chip
                val lp = LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                )
                lp.rightMargin = dp(8)
                row.addView(chip, lp)
            }
            paint(initial)
            val scroll = HorizontalScrollView(context).apply {
                isHorizontalScrollBarEnabled = false
                addView(row)
            }
            root.addView(scroll)
        }

        val typedCategories = config.categories.filter { it.recordType == request.recordType }
        var categories = typedCategories.ifEmpty { config.categories }
        val promptCategoryId = request.categoryId
        val promptCategoryName = request.categoryName
        if (promptCategoryId != null && promptCategoryName != null &&
            categories.none { it.id == promptCategoryId }
        ) {
            categories = listOf(PromptOption(promptCategoryId, promptCategoryName, null)) + categories
        }
        var assets = config.assets
        val promptAssetId = request.assetId
        val promptAssetName = request.assetName
        if (promptAssetId != null && promptAssetName != null &&
            assets.none { it.id == promptAssetId }
        ) {
            assets = listOf(PromptOption(promptAssetId, promptAssetName, null)) + assets
        }
        chipRow("分类", categories, selectedCategoryId) { selectedCategoryId = it }
        chipRow("账户", assets, selectedAssetId) { selectedAssetId = it }

        // Buttons.
        val buttons = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, dp(18), 0, 0)
        }
        val draftId = request.draftId
        val ignore = TextView(context).apply {
            text = "忽略"
            gravity = Gravity.CENTER
            setTextColor(palette.chipText)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            setTypeface(typeface, Typeface.BOLD)
            background = pill(palette.chip, 14)
            setPadding(0, dp(13), 0, dp(13))
            setOnClickListener {
                dismissOnMain()
                AutoBillPromptNotifier.handlePromptAction(
                    context = context,
                    action = AutoBillPromptNotifier.ACTION_IGNORE_DRAFT,
                    draftId = draftId,
                    recordId = null,
                )
            }
        }
        val confirm = TextView(context).apply {
            text = "直接入账"
            gravity = Gravity.CENTER
            setTextColor(palette.onAccent)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            setTypeface(typeface, Typeface.BOLD)
            background = pill(palette.accent, 14)
            setPadding(0, dp(13), 0, dp(13))
            setOnClickListener {
                val remark = remarkField.text?.toString()?.trim().orEmpty()
                dismissOnMain()
                AutoBillPromptNotifier.handlePromptAction(
                    context = context,
                    action = AutoBillPromptNotifier.ACTION_CONFIRM_DRAFT,
                    draftId = draftId,
                    recordId = null,
                    categoryId = selectedCategoryId,
                    assetId = selectedAssetId,
                    remark = remark,
                )
            }
        }
        buttons.addView(ignore, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        val confirmParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 2f)
        confirmParams.leftMargin = dp(12)
        buttons.addView(confirm, confirmParams)
        root.addView(buttons)

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH,
            PixelFormat.TRANSLUCENT,
        )
        params.gravity = Gravity.BOTTOM
        params.softInputMode = WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE or
            WindowManager.LayoutParams.SOFT_INPUT_STATE_HIDDEN
        wm.addView(root, params)
        currentView = root
        currentWindowManager = wm
        return true
    }
}
