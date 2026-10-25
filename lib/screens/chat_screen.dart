import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';

import '../chat/chat_bridge.dart';
import '../chat/chat_config.dart';
import '../utils/app_theme.dart';
import '../utils/app_version.dart';
import '../utils/open_external.dart';
import '../utils/shell_tab.dart';
import '../widgets/app_drawer.dart';
import '../widgets/custom_text.dart';

/// Вкладка «Чат»: конфиденциальный чат SE-chat внутри SE-mobile.
///
/// Внутри — клиент SE-chat из пакета приложения, тот же, что на рабочих ПК.
/// Он не скачивается с сервера: код чата лежит в подписанной сборке, и
/// подменить его, взломав сервер, нельзя. Шифрование, вход и ключи — его,
/// SE-mobile даёт только хранилище, отпечаток и уведомления (ChatBridge).
///
/// Защита вкладки:
/// * никуда, кроме своей страницы, встроенный браузер не переходит —
///   ссылки из переписки открываются снаружи;
/// * пока вкладка на виду, снимки и запись экрана запрещены;
/// * ушли из приложения дольше чем на минуту — ключи стираются из памяти,
///   вернуться можно по отпечатку или ПИН-коду чата;
/// * отладка встроенного браузера включена только в отладочной сборке.
class ChatScreen extends StatefulWidget {
  const ChatScreen({Key? key, this.onNavigate}) : super(key: key);

  final ValueChanged<int>? onNavigate;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  /// Сколько можно пробыть вне приложения, не открывая чат заново.
  ///
  /// Минута, а не ноль: иначе ключи стирались бы при выборе файла для
  /// отправки или взгляде на входящий звонок.
  static const Duration _grace = Duration(minutes: 1);

  /// Собран ли клиент чата в этот пакет (tools/build-chat.sh).
  late final Future<bool> _bundled = _hasBundle();

  InAppWebViewController? _controller;
  Timer? _lockTimer;
  DateTime? _leftAt;
  bool _resumed = true;
  bool? _secure;
  bool? _dark;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ShellTab.selected.addListener(_syncVisibility);
    _syncVisibility();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ShellTab.selected.removeListener(_syncVisibility);
    _lockTimer?.cancel();
    if (ChatBridge.controller == _controller) ChatBridge.controller = null;
    ChatBridge.setVisible(false);
    ChatBridge.setSecure(false);
    super.dispose();
  }

  static Future<bool> _hasBundle() async {
    try {
      await rootBundle.load('$kChatAssetDir/index.html');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Две разные вещи, и снимаются они в разное время.
  ///
  /// Запрет снимков держится, пока выбрана вкладка «Чат», — и когда
  /// приложение свёрнуто тоже: миниатюру для списка недавних система снимает
  /// как раз при сворачивании, и без запрета переписка была бы видна там.
  ///
  /// «Чат на виду» (уведомление о новом сообщении не нужно) — только пока
  /// приложение на экране. Android сбрасывает его сам при уходе с экрана,
  /// поэтому при возвращении отправляем заново, а не только при изменении.
  void _syncVisibility() {
    final selected = ShellTab.selected.value == ChatBridge.tabIndex;
    if (selected != _secure) {
      _secure = selected;
      ChatBridge.setSecure(selected);
    }
    ChatBridge.setVisible(selected && _resumed);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _resumed = false;
        if (_leftAt == null) {
          _leftAt = DateTime.now();
          // Ушли надолго — ключи стираются из памяти страницы, даже если
          // сотрудник так и не вернётся.
          _lockTimer?.cancel();
          _lockTimer = Timer(_grace, _lock);
        }
        break;
      case AppLifecycleState.resumed:
        _lockTimer?.cancel();
        final left = _leftAt;
        _leftAt = null;
        _resumed = true;
        // Таймер мог не сработать: Android замораживает свёрнутое приложение.
        if (left != null && DateTime.now().difference(left) >= _grace) _lock();
        break;
      case AppLifecycleState.inactive:
        _resumed = false;
        break;
    }
    _syncVisibility();
  }

  /// Перезагрузка страницы стирает ключи из её памяти: дальше — отпечаток
  /// или ПИН-код чата.
  void _lock() {
    _lockTimer?.cancel();
    _lockTimer = null;
    _leftAt = null;
    _controller?.reload();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (_dark != null && _dark != dark) ChatBridge.setTheme(dark);
    _dark = dark;
  }

  /// Сведения для клиента чата — до загрузки его кода.
  UserScript _hostScript() {
    final config = jsonEncode({
      'host': 'se-mobile',
      'serverUrl': kChatUrl,
      'theme': (_dark ?? false) ? 'dark' : 'light',
      'version': kAppVersion,
    });
    return UserScript(
      source: 'window.__SE_HOST__ = Object.freeze($config);',
      injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
    );
  }

  Future<NavigationActionPolicy> _navigation(
      InAppWebViewController controller, NavigationAction action) async {
    final uri = action.request.url;
    if (uri != null && uri.host == WebViewAssetLoader.DEFAULT_DOMAIN) {
      return NavigationActionPolicy.ALLOW;
    }
    // Ссылка из переписки — в обычном браузере, не здесь: внутри вкладки
    // чужая страница получила бы доступ к мосту.
    if (uri != null && uri.scheme == 'https' && action.isForMainFrame && mounted) {
      openExternal(context, uri.toString());
    }
    return NavigationActionPolicy.CANCEL;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.pageColor,
      drawer: widget.onNavigate == null
          ? null
          : AppDrawer(onNavigate: widget.onNavigate, currentIndex: ChatBridge.tabIndex),
      appBar: AppBar(
        leading: widget.onNavigate == null
            ? null
            : Builder(
                builder: (context) => IconButton(
                  icon: const Icon(Icons.menu),
                  tooltip: MaterialLocalizations.of(context).openAppDrawerTooltip,
                  onPressed: () => Scaffold.of(context).openDrawer(),
                ),
              ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            BigText(content: 'tab_chat'.tr, color: Colors.white),
            const SizedBox(width: 8),
            Tooltip(
              message: 'chat_e2e_hint'.tr,
              child: const Icon(Icons.lock_outline, size: 18, color: Colors.white70),
            ),
          ],
        ),
      ),
      body: FutureBuilder<bool>(
        future: _bundled,
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const SizedBox.shrink();
          if (snapshot.data != true) return _message('chat_not_bundled'.tr);
          if (_loadError != null) return _message(_loadError!, retry: true);
          return _webView();
        },
      ),
    );
  }

  Widget _webView() {
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(kChatPageUrl)),
      initialUserScripts: UnmodifiableListView([_hostScript()]),
      initialSettings: InAppWebViewSettings(
        webViewAssetLoader: WebViewAssetLoader(
          pathHandlers: [AssetsPathHandler(path: '/assets/')],
        ),
        javaScriptEnabled: true,
        // Файлы телефона странице не нужны: всё её — в пакете приложения.
        allowFileAccess: false,
        allowContentAccess: false,
        allowFileAccessFromFileURLs: false,
        allowUniversalAccessFromFileURLs: false,
        javaScriptCanOpenWindowsAutomatically: false,
        supportMultipleWindows: false,
        thirdPartyCookiesEnabled: false,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
        geolocationEnabled: false,
        saveFormData: false,
        supportZoom: false,
        transparentBackground: true,
        useShouldOverrideUrlLoading: true,
        isInspectable: kDebugMode,
      ),
      onWebViewCreated: (controller) {
        _controller = controller;
        ChatBridge.controller = controller;
        controller.addJavaScriptHandler(
            handlerName: 'sechat', callback: ChatBridge.handle);
      },
      shouldOverrideUrlLoading: _navigation,
      onReceivedError: (controller, request, error) {
        if (request.isForMainFrame != true || !mounted) return;
        setState(() => _loadError = 'chat_load_error'.tr);
      },
      // Микрофон, камеру и прочее чату не даём: он ими не пользуется.
      onPermissionRequest: (controller, request) async =>
          PermissionResponse(resources: request.resources, action: PermissionResponseAction.DENY),
    );
  }

  Widget _message(String text, {bool retry = false}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined, size: 48, color: context.mutedColor),
            const SizedBox(height: 16),
            Text(text, textAlign: TextAlign.center, style: TextStyle(color: context.mutedColor)),
            if (retry) ...[
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => setState(() => _loadError = null),
                child: Text('try_again'.tr),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
