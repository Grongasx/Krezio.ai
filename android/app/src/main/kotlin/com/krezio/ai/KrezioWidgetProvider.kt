package com.krezio.ai

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * Home screen widget: the month's balance and a "Falar com o César" button.
 * The app writes the values (HomeWidgetSync in Dart) after every change.
 */
class KrezioWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.krezio_widget).apply {
                setTextViewText(R.id.widget_balance, widgetData.getString("month_balance", "R$ 0,00"))
                setTextViewText(R.id.widget_detail, widgetData.getString("month_detail", "Abra o app para atualizar"))
                setOnClickPendingIntent(
                    R.id.widget_root,
                    HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java, Uri.parse("krezio://app/")),
                )
                setOnClickPendingIntent(
                    R.id.widget_talk,
                    HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java, Uri.parse("krezio://app/chat?voz=1")),
                )
            }
            appWidgetManager.updateAppWidget(id, views)
        }
    }
}
