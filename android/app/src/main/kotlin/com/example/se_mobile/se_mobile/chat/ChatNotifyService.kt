package com.example.se_mobile.se_mobile.chat

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import com.example.se_mobile.se_mobile.MainActivity
import com.example.se_mobile.se_mobile.R
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.concurrent.TimeUnit

/**
 * Уведомления конфиденциального чата — без Firebase.
 *
 * Перенесено из приложения SE-chat (NotifyService.java) без изменений по
 * сути. Служба держит WebSocket с сервером чата `/ws/notify` по узкому
 * токену и показывает «Новое сообщение», когда сервер сообщает о новом
 * сообщении. Сигнал идёт напрямую с сервера предприятия: ни Google, ни
 * сервер SE-mobile не узнают, кто и когда переписывается. Уведомления
 * самого SE-mobile (новости, заявки) по-прежнему идут через Firebase —
 * это разные каналы.
 *
 * Расшифровать сообщение служба не может и не пытается: ключи живут в
 * веб-слое вкладки «Чат». Поэтому уведомление всегда нейтральное.
 */
class ChatNotifyService : Service() {

    companion object {
        private const val TAG = "SEChatNotify"

        private const val PREFS = "sechat.notify"
        private const val KEY_SERVER = "server"
        private const val KEY_TOKEN = "token"
        private const val KEY_ENABLED = "enabled"

        private const val CHANNEL_SERVICE = "sechat.service"
        private const val CHANNEL_MESSAGES = "sechat.messages"

        private const val NOTIFICATION_SERVICE = 7101
        private const val NOTIFICATION_MESSAGE = 7102

        private const val RECONNECT_MIN_MS = 2_000L
        private const val RECONNECT_MAX_MS = 120_000L

        /** По нажатию на уведомление SE-mobile открывает вкладку «Чат». */
        const val EXTRA_OPEN_CHAT = "se_mobile.open_chat"

        /**
         * Вкладка «Чат» открыта и на виду — уведомление только мешало бы:
         * сообщение и так появится на экране.
         */
        @Volatile
        var chatVisible = false

        @Volatile
        var running = false
            private set

        /** Сохраняет настройки канала и запускает службу. */
        fun start(context: Context, serverUrl: String, token: String) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString(KEY_SERVER, serverUrl)
                .putString(KEY_TOKEN, token)
                .putBoolean(KEY_ENABLED, true)
                .apply()

            val intent = Intent(context, ChatNotifyService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putBoolean(KEY_ENABLED, false)
                .remove(KEY_TOKEN)
                .apply()
            context.stopService(Intent(context, ChatNotifyService::class.java))
        }

        /** Включал ли сотрудник уведомления чата — нужно после перезагрузки. */
        fun isEnabled(context: Context): Boolean {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            return prefs.getBoolean(KEY_ENABLED, false) && prefs.getString(KEY_TOKEN, null) != null
        }

        fun storedServer(context: Context): String =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_SERVER, "") ?: ""

        fun storedToken(context: Context): String =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_TOKEN, "") ?: ""
    }

    private val handler = Handler(Looper.getMainLooper())
    private lateinit var client: OkHttpClient
    private var socket: WebSocket? = null
    private var reconnectDelay = RECONNECT_MIN_MS
    private var stopping = false

    /**
     * Номер поколения соединения. Закрытое соединение ещё какое-то время
     * присылает события; по номеру видно, что они от прошлой попытки.
     */
    private var generation = 0

    override fun onCreate() {
        super.onCreate()
        createChannels()
        client = OkHttpClient.Builder()
            // Молчащее соединение — признак разрыва, о котором система не
            // сообщила. Пинги вскрывают это за полминуты.
            .pingInterval(30, TimeUnit.SECONDS)
            .retryOnConnectionFailure(true)
            .build()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundSafely()

        if (!isEnabled(this)) {
            stopSelf()
            return START_NOT_STICKY
        }

        running = true
        stopping = false
        connect()
        return START_STICKY
    }

    override fun onDestroy() {
        stopping = true
        running = false
        handler.removeCallbacksAndMessages(null)
        socket?.close(1000, "Служба остановлена")
        socket = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // --- Соединение ----------------------------------------------------------

    private fun connect() {
        if (stopping) return

        // Повторный запуск поверх работающей службы не должен давать второе
        // соединение: сигнал пришёл бы дважды.
        socket?.close(1000, "Переподключение")
        socket = null

        val server = storedServer(this)
        val token = storedToken(this)
        if (server.isEmpty() || token.isEmpty()) {
            stopSelf()
            return
        }

        generation += 1
        val url = server.replaceFirst(Regex("^http"), "ws") + "/ws/notify?token=" + token
        socket = client.newWebSocket(Request.Builder().url(url).build(), Listener(generation))
    }

    private fun scheduleReconnect() {
        if (stopping) return
        handler.postDelayed({ connect() }, reconnectDelay)
        // Постепенно реже: при долгом отсутствии сети не сажаем батарею.
        reconnectDelay = minOf(reconnectDelay * 2, RECONNECT_MAX_MS)
    }

    /** События OkHttp переносятся в главный поток: всё состояние живёт там. */
    private inner class Listener(private val mine: Int) : WebSocketListener() {

        private fun stale() = mine != generation || stopping

        override fun onOpen(webSocket: WebSocket, response: Response) {
            handler.post {
                if (!stale()) reconnectDelay = RECONNECT_MIN_MS
            }
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            // По этому каналу приходит только сигнал пробуждения и ping:
            // содержимого в кадре нет.
            val wake = text.contains("\"wake\"")
            handler.post {
                if (!stale() && wake) notifyNewMessage()
            }
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            val code = response?.code ?: 0
            handler.post {
                if (stale()) return@post
                Log.i(TAG, "Соединение потеряно: ${t.message}")
                socket = null
                if (code == 401) {
                    // Токен отозван: выход из чата или устройство отключено.
                    stop(this@ChatNotifyService)
                    return@post
                }
                scheduleReconnect()
            }
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            handler.post {
                if (stale()) return@post
                socket = null
                if (code == 4401) {
                    stop(this@ChatNotifyService)
                    return@post
                }
                scheduleReconnect()
            }
        }
    }

    // --- Уведомления ---------------------------------------------------------

    private fun createChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)

        val service = NotificationChannel(
            CHANNEL_SERVICE, "Чат: работа в фоне", NotificationManager.IMPORTANCE_MIN
        )
        service.description = "Постоянное соединение с сервером чата предприятия"
        service.setShowBadge(false)
        manager.createNotificationChannel(service)

        val messages = NotificationChannel(
            CHANNEL_MESSAGES, "Чат: новые сообщения", NotificationManager.IMPORTANCE_HIGH
        )
        messages.description = "Уведомления о сообщениях в конфиденциальном чате"
        manager.createNotificationChannel(messages)
    }

    private fun openChat(): PendingIntent {
        val intent = Intent(this, MainActivity::class.java)
            .putExtra(EXTRA_OPEN_CHAT, true)
            .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(
            this, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun startForegroundSafely() {
        val notification = NotificationCompat.Builder(this, CHANNEL_SERVICE)
            .setContentTitle("SE Mobile")
            .setContentText("Уведомления чата включены")
            .setSmallIcon(R.drawable.ic_stat_chat)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(openChat())
            .build()

        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
        } else {
            0
        }
        ServiceCompat.startForeground(this, NOTIFICATION_SERVICE, notification, type)
    }

    private fun notifyNewMessage() {
        if (chatVisible) return

        val notification: Notification = NotificationCompat.Builder(this, CHANNEL_MESSAGES)
            .setContentTitle("Чат")
            // Ни отправителя, ни текста здесь быть не может: служба видит
            // только сам факт сообщения.
            .setContentText("Новое сообщение")
            .setSmallIcon(R.drawable.ic_stat_chat)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setAutoCancel(true)
            .setContentIntent(openChat())
            .build()

        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_MESSAGE, notification)
    }
}
