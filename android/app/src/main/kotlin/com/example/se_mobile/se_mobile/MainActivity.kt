package com.example.se_mobile.se_mobile

import io.flutter.embedding.android.FlutterFragmentActivity

// FlutterFragmentActivity, а не FlutterActivity: системное окно отпечатка
// (BiometricPrompt) рисуется фрагментом и без него не открывается.
class MainActivity: FlutterFragmentActivity() {
}
