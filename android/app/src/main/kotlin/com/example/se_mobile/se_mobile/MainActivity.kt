package com.example.se_mobile.se_mobile

import io.flutter.embedding.android.FlutterFragmentActivity

// FragmentActivity, а не обычная Activity: системное окно отпечатка пальца
// (local_auth, BiometricPrompt) показывается фрагментом и без неё не открывается.
class MainActivity: FlutterFragmentActivity() {
}
