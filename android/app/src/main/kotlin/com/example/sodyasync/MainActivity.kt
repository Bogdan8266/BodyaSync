package com.example.sodyasync // Перевір, що пакет правильний

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import android.os.Build
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import androidx.core.view.WindowCompat


class MainActivity: FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // ID каналу, який ти використовуєш в Dart
            val channelId = "my_app_sync_channel" 
            // Назва каналу, яку бачить користувач в налаштуваннях
            val channelName = "Синхронізація"
            // Створюємо канал
            val channel = NotificationChannel(
                channelId,
                channelName,
                NotificationManager.IMPORTANCE_LOW // Низький пріоритет, без звуку
            )
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
            WindowCompat.setDecorFitsSystemWindows(window, false)
        }
    }
}