package com.tallyisle.app

import android.app.PendingIntent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/**
 * Quick Settings tile "智能记账": collapses the shade and opens TallyIsle's smart-bill sheet via the
 * `shortcut` payload (`shortcutAction = "smart_bill"`, `source = "tile"`).
 */
class QuickBillTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        qsTile?.let { tile ->
            tile.state = Tile.STATE_INACTIVE
            tile.updateTile()
        }
    }

    override fun onClick() {
        super.onClick()
        val launch = { openSmartBill() }
        if (isLocked) unlockAndRun(launch) else launch()
    }

    @Suppress("DEPRECATION")
    private fun openSmartBill() {
        val intent = AutomationBridge.buildShortcutIntent(
            this,
            AutomationBridge.SHORTCUT_SMART_BILL,
            AutomationBridge.SOURCE_TILE,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startActivityAndCollapse(
                PendingIntent.getActivity(
                    this,
                    QUICK_TILE_REQUEST_CODE,
                    intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )
        } else {
            startActivityAndCollapse(intent)
        }
    }

    private companion object {
        const val QUICK_TILE_REQUEST_CODE = 9001
    }
}
