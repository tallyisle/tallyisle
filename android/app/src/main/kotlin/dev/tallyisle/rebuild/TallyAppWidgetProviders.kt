package dev.tallyisle.rebuild

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.widget.RemoteViews

data class PersistedWidgetSnapshot(
    val bookName: String,
    val periodLabel: String,
    val currencySymbol: String,
    val expenseMinor: String,
    val incomeMinor: String,
    val balanceMinor: String,
    val todayExpenseMinor: String,
    val budgetRemainingMinor: String?,
    val expenseFormatted: String,
    val incomeFormatted: String,
    val balanceFormatted: String,
    val todayExpenseFormatted: String,
    val budgetRemainingFormatted: String?,
    val updatedAtMs: Long,
)

/**
 * Shared persistence and `RemoteViews` renderer for TallyIsle desktop widgets (`F-034`).
 *
 * Uses `context.resources.getIdentifier(...)` exclusively so Kotlin compiles cleanly both
 * under standalone `K2JVMCompiler -Werror` and full Gradle AAPT2 builds.
 * Amounts are persisted as exact integer-minor strings and pre-formatted decimal strings
 * with zero floating-point types (`ADR-011`).
 */
object TallyWidgetStore {
    const val PREFS_NAME = "tallyisle_widgets"
    const val KIND_QUICK_ADD = "quick_add"
    const val KIND_MONTH_SUMMARY = "month_summary"
    const val KIND_MONTH_BAR = "month_bar"

    private const val EXTRA_LAUNCH_ROUTE = "dev.tallyisle.rebuild.extra.LAUNCH_ROUTE"
    private const val MAIN_ACTIVITY_CLASS = "dev.tallyisle.rebuild.MainActivity"

    private const val KEY_BOOK_NAME = "book_name"
    private const val KEY_PERIOD_LABEL = "period_label"
    private const val KEY_CURRENCY_SYMBOL = "currency_symbol"
    private const val KEY_EXPENSE_MINOR = "expense_minor"
    private const val KEY_INCOME_MINOR = "income_minor"
    private const val KEY_BALANCE_MINOR = "balance_minor"
    private const val KEY_TODAY_EXPENSE_MINOR = "today_expense_minor"
    private const val KEY_BUDGET_REMAINING_MINOR = "budget_remaining_minor"
    private const val KEY_EXPENSE_FORMATTED = "expense_formatted"
    private const val KEY_INCOME_FORMATTED = "income_formatted"
    private const val KEY_BALANCE_FORMATTED = "balance_formatted"
    private const val KEY_TODAY_EXPENSE_FORMATTED = "today_expense_formatted"
    private const val KEY_BUDGET_REMAINING_FORMATTED = "budget_remaining_formatted"
    private const val KEY_UPDATED_AT_MS = "updated_at_ms"

    fun saveSnapshot(context: Context, snapshot: PersistedWidgetSnapshot) {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val editor = prefs.edit()
            .putString(KEY_BOOK_NAME, snapshot.bookName)
            .putString(KEY_PERIOD_LABEL, snapshot.periodLabel)
            .putString(KEY_CURRENCY_SYMBOL, snapshot.currencySymbol)
            .putString(KEY_EXPENSE_MINOR, snapshot.expenseMinor)
            .putString(KEY_INCOME_MINOR, snapshot.incomeMinor)
            .putString(KEY_BALANCE_MINOR, snapshot.balanceMinor)
            .putString(KEY_TODAY_EXPENSE_MINOR, snapshot.todayExpenseMinor)
            .putString(KEY_EXPENSE_FORMATTED, snapshot.expenseFormatted)
            .putString(KEY_INCOME_FORMATTED, snapshot.incomeFormatted)
            .putString(KEY_BALANCE_FORMATTED, snapshot.balanceFormatted)
            .putString(KEY_TODAY_EXPENSE_FORMATTED, snapshot.todayExpenseFormatted)
            .putLong(KEY_UPDATED_AT_MS, snapshot.updatedAtMs)
        if (snapshot.budgetRemainingMinor != null && snapshot.budgetRemainingFormatted != null) {
            editor.putString(KEY_BUDGET_REMAINING_MINOR, snapshot.budgetRemainingMinor)
            editor.putString(KEY_BUDGET_REMAINING_FORMATTED, snapshot.budgetRemainingFormatted)
        } else {
            editor.remove(KEY_BUDGET_REMAINING_MINOR)
            editor.remove(KEY_BUDGET_REMAINING_FORMATTED)
        }
        editor.commit()
    }

    fun loadSnapshot(context: Context): PersistedWidgetSnapshot {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return PersistedWidgetSnapshot(
            bookName = prefs.getString(KEY_BOOK_NAME, "日常账本") ?: "日常账本",
            periodLabel = prefs.getString(KEY_PERIOD_LABEL, "本期") ?: "本期",
            currencySymbol = prefs.getString(KEY_CURRENCY_SYMBOL, "¥") ?: "¥",
            expenseMinor = prefs.getString(KEY_EXPENSE_MINOR, "0") ?: "0",
            incomeMinor = prefs.getString(KEY_INCOME_MINOR, "0") ?: "0",
            balanceMinor = prefs.getString(KEY_BALANCE_MINOR, "0") ?: "0",
            todayExpenseMinor = prefs.getString(KEY_TODAY_EXPENSE_MINOR, "0") ?: "0",
            budgetRemainingMinor = prefs.getString(KEY_BUDGET_REMAINING_MINOR, null),
            expenseFormatted = prefs.getString(KEY_EXPENSE_FORMATTED, "0.00") ?: "0.00",
            incomeFormatted = prefs.getString(KEY_INCOME_FORMATTED, "0.00") ?: "0.00",
            balanceFormatted = prefs.getString(KEY_BALANCE_FORMATTED, "0.00") ?: "0.00",
            todayExpenseFormatted = prefs.getString(KEY_TODAY_EXPENSE_FORMATTED, "0.00") ?: "0.00",
            budgetRemainingFormatted = prefs.getString(KEY_BUDGET_REMAINING_FORMATTED, null),
            updatedAtMs = prefs.getLong(KEY_UPDATED_AT_MS, 0L),
        )
    }

    fun updateAllWidgets(context: Context): Map<String, Int> {
        val appContext = context.applicationContext
        val manager = AppWidgetManager.getInstance(appContext)
        val snapshot = loadSnapshot(appContext)

        val quickIds = manager.getAppWidgetIds(ComponentName(appContext, QuickAddWidgetProvider::class.java))
        for (id in quickIds) {
            renderQuickAdd(appContext, manager, id)
        }

        val summaryIds = manager.getAppWidgetIds(ComponentName(appContext, MonthSummaryWidgetProvider::class.java))
        for (id in summaryIds) {
            renderMonthSummary(appContext, manager, id, snapshot)
        }

        val barIds = manager.getAppWidgetIds(ComponentName(appContext, MonthBarWidgetProvider::class.java))
        for (id in barIds) {
            renderMonthBar(appContext, manager, id, snapshot)
        }

        return mapOf(
            KIND_QUICK_ADD to quickIds.size,
            KIND_MONTH_SUMMARY to summaryIds.size,
            KIND_MONTH_BAR to barIds.size,
        )
    }

    fun getActiveWidgetCounts(context: Context): Map<String, Int> {
        val appContext = context.applicationContext
        val manager = AppWidgetManager.getInstance(appContext)
        return mapOf(
            KIND_QUICK_ADD to manager.getAppWidgetIds(
                ComponentName(appContext, QuickAddWidgetProvider::class.java),
            ).size,
            KIND_MONTH_SUMMARY to manager.getAppWidgetIds(
                ComponentName(appContext, MonthSummaryWidgetProvider::class.java),
            ).size,
            KIND_MONTH_BAR to manager.getAppWidgetIds(
                ComponentName(appContext, MonthBarWidgetProvider::class.java),
            ).size,
        )
    }

    fun requestPinWidget(context: Context, kind: String): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val appContext = context.applicationContext
        val manager = AppWidgetManager.getInstance(appContext)
        if (!manager.isRequestPinAppWidgetSupported) return false
        val provider = when (kind) {
            KIND_QUICK_ADD -> ComponentName(appContext, QuickAddWidgetProvider::class.java)
            KIND_MONTH_SUMMARY -> ComponentName(appContext, MonthSummaryWidgetProvider::class.java)
            KIND_MONTH_BAR -> ComponentName(appContext, MonthBarWidgetProvider::class.java)
            else -> return false
        }
        return try {
            manager.requestPinAppWidget(provider, null, null)
        } catch (_: Exception) {
            false
        }
    }

    internal fun renderQuickAdd(
        context: Context,
        manager: AppWidgetManager,
        appWidgetId: Int,
    ) {
        val layoutId = resId(context, "widget_quick_add", "layout")
        if (layoutId == 0) return
        val views = RemoteViews(context.packageName, layoutId)
        val rootId = resId(context, "widget_quick_root", "id")
        if (rootId != 0) {
            views.setOnClickPendingIntent(
                rootId,
                buildDeepLinkPendingIntent(
                    context = context,
                    requestCode = 7100 + (appWidgetId and 0x3FF),
                    uriString = "tallyisle://newbill",
                    launchRoute = "/record/new",
                ),
            )
        }
        manager.updateAppWidget(appWidgetId, views)
    }

    internal fun renderMonthSummary(
        context: Context,
        manager: AppWidgetManager,
        appWidgetId: Int,
        snapshot: PersistedWidgetSnapshot = loadSnapshot(context),
    ) {
        val layoutId = resId(context, "widget_month_summary", "layout")
        if (layoutId == 0) return
        val views = RemoteViews(context.packageName, layoutId)
        val sym = snapshot.currencySymbol

        val headerId = resId(context, "widget_summary_header", "id")
        if (headerId != 0) {
            views.setTextViewText(headerId, "${snapshot.bookName} · ${snapshot.periodLabel}")
        }
        val expenseId = resId(context, "widget_summary_expense_value", "id")
        if (expenseId != 0) {
            views.setTextViewText(expenseId, "$sym${snapshot.expenseFormatted}")
        }
        val incomeId = resId(context, "widget_summary_income_value", "id")
        if (incomeId != 0) {
            views.setTextViewText(incomeId, "收入 $sym${snapshot.incomeFormatted}")
        }
        val balanceId = resId(context, "widget_summary_balance_value", "id")
        if (balanceId != 0) {
            val secondaryText = if (snapshot.budgetRemainingFormatted != null) {
                "预算剩余 $sym${snapshot.budgetRemainingFormatted}"
            } else {
                "结余 $sym${snapshot.balanceFormatted}"
            }
            views.setTextViewText(balanceId, secondaryText)
        }

        val rootId = resId(context, "widget_summary_root", "id")
        if (rootId != 0) {
            views.setOnClickPendingIntent(
                rootId,
                buildDeepLinkPendingIntent(
                    context = context,
                    requestCode = 7200 + (appWidgetId and 0x3FF),
                    uriString = "tallyisle://home",
                    launchRoute = "/",
                ),
            )
        }
        val addBtnId = resId(context, "widget_summary_add_btn", "id")
        if (addBtnId != 0) {
            views.setOnClickPendingIntent(
                addBtnId,
                buildDeepLinkPendingIntent(
                    context = context,
                    requestCode = 7600 + (appWidgetId and 0x3FF),
                    uriString = "tallyisle://newbill",
                    launchRoute = "/record/new",
                ),
            )
        }
        manager.updateAppWidget(appWidgetId, views)
    }

    internal fun renderMonthBar(
        context: Context,
        manager: AppWidgetManager,
        appWidgetId: Int,
        snapshot: PersistedWidgetSnapshot = loadSnapshot(context),
    ) {
        val layoutId = resId(context, "widget_month_bar", "layout")
        if (layoutId == 0) return
        val views = RemoteViews(context.packageName, layoutId)
        val sym = snapshot.currencySymbol

        val bookId = resId(context, "widget_bar_book", "id")
        if (bookId != 0) {
            views.setTextViewText(bookId, "${snapshot.bookName}支出")
        }
        val expId = resId(context, "widget_bar_expense", "id")
        if (expId != 0) {
            views.setTextViewText(expId, "$sym${snapshot.expenseFormatted}")
        }
        val incId = resId(context, "widget_bar_income", "id")
        if (incId != 0) {
            views.setTextViewText(incId, "$sym${snapshot.incomeFormatted}")
        }
        val todayId = resId(context, "widget_bar_today", "id")
        if (todayId != 0) {
            views.setTextViewText(todayId, "$sym${snapshot.todayExpenseFormatted}")
        }

        val rootId = resId(context, "widget_bar_root", "id")
        if (rootId != 0) {
            views.setOnClickPendingIntent(
                rootId,
                buildDeepLinkPendingIntent(
                    context = context,
                    requestCode = 8100 + (appWidgetId and 0x3FF),
                    uriString = "tallyisle://home",
                    launchRoute = "/",
                ),
            )
        }
        val addBtnId = resId(context, "widget_bar_add_btn", "id")
        if (addBtnId != 0) {
            views.setOnClickPendingIntent(
                addBtnId,
                buildDeepLinkPendingIntent(
                    context = context,
                    requestCode = 8500 + (appWidgetId and 0x3FF),
                    uriString = "tallyisle://newbill",
                    launchRoute = "/record/new",
                ),
            )
        }
        manager.updateAppWidget(appWidgetId, views)
    }

    private fun buildDeepLinkPendingIntent(
        context: Context,
        requestCode: Int,
        uriString: String,
        launchRoute: String,
    ): PendingIntent {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(uriString)).apply {
            component = ComponentName(context.packageName, MAIN_ACTIVITY_CLASS)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(EXTRA_LAUNCH_ROUTE, launchRoute)
        }
        return PendingIntent.getActivity(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun resId(context: Context, name: String, defType: String): Int =
        context.resources.getIdentifier(name, defType, context.packageName)
}

/** 1×1 Quick-Add desktop AppWidget (`F-034`). */
class QuickAddWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        for (id in appWidgetIds) {
            TallyWidgetStore.renderQuickAdd(context, appWidgetManager, id)
        }
    }
}

/** 2×2 Monthly Income/Expense Summary desktop AppWidget (`F-034`). */
class MonthSummaryWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        val snapshot = TallyWidgetStore.loadSnapshot(context)
        for (id in appWidgetIds) {
            TallyWidgetStore.renderMonthSummary(context, appWidgetManager, id, snapshot)
        }
    }
}

/** 4×1 Monthly Compact Bar desktop AppWidget (`F-034`). */
class MonthBarWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        val snapshot = TallyWidgetStore.loadSnapshot(context)
        for (id in appWidgetIds) {
            TallyWidgetStore.renderMonthBar(context, appWidgetManager, id, snapshot)
        }
    }
}
