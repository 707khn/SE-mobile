package com.example.se_mobile.se_mobile.chat

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Мост между вкладкой «Чат» (Dart) и Android.
 *
 * Здесь только то, чего нет в готовых плагинах: служба уведомлений чата,
 * запрет снимков экрана на время, пока открыт чат, и нажатие на
 * уведомление. Хранилище и отпечаток идут через flutter_secure_storage и
 * local_auth, как и в остальном SE-mobile.
 */
class ChatChannel(private val activity: Activity, messenger: BinaryMessenger) {

    companion object {
        const val NAME = "se_mobile/chat"
        private const val REQUEST_NOTIFICATIONS = 7103
    }

    private val channel = MethodChannel(messenger, NAME)
    private var pendingPermission: MethodChannel.Result? = null

    /** Нажатие на уведомление пришло до того, как Dart был готов его принять. */
    private var openChatPending = false

    private val context: Context get() = activity.applicationContext

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(
                    mapOf(
                        "running" to (ChatNotifyService.running && ChatNotifyService.isEnabled(context)),
                        "permitted" to hasNotificationPermission(),
                        "batteryExempt" to isBatteryExempt(),
                    )
                )
                "start" -> {
                    val server = call.argument<String>("serverUrl").orEmpty()
                    val token = call.argument<String>("token").orEmpty()
                    if (server.isEmpty() || token.isEmpty()) {
                        result.error("args", "Не указан адрес сервера или токен канала", null)
                    } else {
                        ChatNotifyService.start(context, server, token)
                        result.success(null)
                    }
                }
                "stop" -> {
                    ChatNotifyService.stop(context)
                    result.success(null)
                }
                "requestPermission" -> requestPermission(result)
                "requestBatteryExemption" -> {
                    requestBatteryExemption()
                    result.success(null)
                }
                "setChatVisible" -> {
                    ChatNotifyService.chatVisible = call.argument<Boolean>("visible") == true
                    result.success(null)
                }
                "setSecure" -> {
                    // Пока открыт чат, переписку нельзя снять скриншотом или
                    // записью экрана, и её не видно в списке недавних.
                    if (call.argument<Boolean>("secure") == true) {
                        activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    } else {
                        activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(null)
                }
                "takeOpenRequest" -> {
                    result.success(openChatPending)
                    openChatPending = false
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Нажатие на уведомление чата: открыть вкладку «Чат». */
    fun handleIntent(intent: Intent?) {
        if (intent?.getBooleanExtra(ChatNotifyService.EXTRA_OPEN_CHAT, false) != true) return
        intent.removeExtra(ChatNotifyService.EXTRA_OPEN_CHAT)
        openChatPending = true
        channel.invokeMethod("openChat", null)
    }

    fun onPause() {
        ChatNotifyService.chatVisible = false
    }

    fun onRequestPermissionsResult(requestCode: Int): Boolean {
        if (requestCode != REQUEST_NOTIFICATIONS) return false
        pendingPermission?.success(mapOf("granted" to hasNotificationPermission()))
        pendingPermission = null
        return true
    }

    private fun requestPermission(result: MethodChannel.Result) {
        if (hasNotificationPermission() || Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(mapOf("granted" to hasNotificationPermission()))
            return
        }
        pendingPermission?.success(mapOf("granted" to false))
        pendingPermission = result
        ActivityCompat.requestPermissions(
            activity, arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS
        )
    }

    /**
     * Без исключения из экономии батареи телефон рано или поздно выгрузит
     * службу, и уведомления прекратятся молча.
     */
    private fun requestBatteryExemption() {
        if (isBatteryExempt()) return
        try {
            activity.startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:" + context.packageName)
                )
            )
        } catch (denied: Exception) {
            // Некоторые прошивки прячут этот экран — открываем общий список.
            try {
                activity.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            } catch (_: Exception) {
            }
        }
    }

    private fun hasNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun isBatteryExempt(): Boolean {
        val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager? ?: return true
        return power.isIgnoringBatteryOptimizations(context.packageName)
    }
}
