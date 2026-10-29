package com.example.se_mobile.se_mobile.chat

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Возобновляет канал уведомлений чата после перезагрузки телефона и после
 * обновления приложения — иначе уведомления молча прекращались бы до
 * следующего запуска SE-mobile.
 */
class ChatBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action
        if (action != Intent.ACTION_BOOT_COMPLETED && action != Intent.ACTION_MY_PACKAGE_REPLACED) {
            return
        }
        if (!ChatNotifyService.isEnabled(context)) return

        val server = ChatNotifyService.storedServer(context)
        val token = ChatNotifyService.storedToken(context)
        if (server.isEmpty() || token.isEmpty()) return
        ChatNotifyService.start(context, server, token)
    }
}
