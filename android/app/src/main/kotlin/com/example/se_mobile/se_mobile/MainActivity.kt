package com.example.se_mobile.se_mobile

import android.content.Intent
import android.os.Bundle
import com.example.se_mobile.se_mobile.chat.ChatChannel
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

// FlutterFragmentActivity, а не FlutterActivity: системное окно отпечатка
// (BiometricPrompt) рисуется фрагментом и без него не открывается.
class MainActivity: FlutterFragmentActivity() {

    private var chat: ChatChannel? = null

    /**
     * Окно пересоздано системой, а не открыто заново. Intent у него тот же,
     * что при первом запуске, и нажатие на уведомление в нём — давнее.
     */
    private var restored = false

    override fun onCreate(savedInstanceState: Bundle?) {
        restored = savedInstanceState != null
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        chat = ChatChannel(this, flutterEngine.dartExecutor.binaryMessenger).also {
            // Приложение запустили нажатием на уведомление чата.
            if (!restored) it.handleIntent(intent)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        chat?.handleIntent(intent)
    }

    override fun onPause() {
        chat?.onPause()
        super.onPause()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        if (chat?.onRequestPermissionsResult(requestCode) == true) return
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }
}
