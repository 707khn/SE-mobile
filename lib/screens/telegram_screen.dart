import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../requests/telegram_request.dart';
import '../utils/app_theme.dart';
import '../utils/load_problem.dart';
import '../utils/open_external.dart';
import '../widgets/load_error_view.dart';

/// «Уведомления в Telegram»: подключить, дождаться, отключить.
///
/// Для веб-версии: у браузера уведомлений на телефон нет, а Telegram есть
/// почти у всех. Присылает бот предприятия — то же, что Android-телефонам
/// приходит пушем.
///
/// Подключение — в два касания. «Подключить» берёт у сервера одноразовую
/// ссылку на бота, «Открыть Telegram» её открывает. Одним касанием нельзя:
/// Safari открывает ссылку в новом окне только прямо по касанию, а не когда
/// ответил сервер, — и молча не открыл бы ничего.
///
/// Пока человек в Telegram нажимает «Запустить», экран раз в несколько
/// секунд спрашивает сервер, подключено ли, — и сразу, как только к нему
/// вернулись.
class TelegramScreen extends StatefulWidget {
  const TelegramScreen({super.key});

  @override
  State<TelegramScreen> createState() => _TelegramScreenState();
}

enum _Stage { loading, failed, off, waiting, linked }

class _TelegramScreenState extends State<TelegramScreen>
    with WidgetsBindingObserver {
  static const _pollEvery = Duration(seconds: 3);

  _Stage _stage = _Stage.loading;
  LoadProblem? _problem;
  bool _enabled = true;
  bool _busy = false;

  /// Ссылка на бота, пока ждём «Запустить».
  String? _url;
  DateTime? _expiresAt;
  Duration _lifetime = const Duration(minutes: 30);

  /// Ссылка истекла, а «Запустить» так и не нажали.
  bool _expired = false;

  Timer? _poll;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Вернулись из Telegram — спросить сразу, не дожидаясь очередного раза.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _load() async {
    setState(() {
      _stage = _Stage.loading;
      _problem = null;
    });
    try {
      final state = await fetchTelegramState();
      if (!mounted) return;
      setState(() {
        _enabled = state.enabled;
        _stage = state.linked ? _Stage.linked : _Stage.off;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.failed;
        _problem = problemOfAny(e);
      });
    }
  }

  Future<void> _connect() async {
    HapticFeedback.selectionClick();
    setState(() => _busy = true);
    final link = await requestTelegramLink();
    if (!mounted) return;
    setState(() => _busy = false);
    final url = link.url;
    if (url == null) {
      if (link.problem != null || link.error != null) {
        _say(link.error == 'telegram_unavailable'
            ? 'tg_unavailable'.tr
            : problemMessage(link.problem));
      }
      return;
    }
    setState(() {
      _url = url;
      _lifetime = link.lifetime;
      _expiresAt = DateTime.now().add(link.lifetime);
      _expired = false;
      _stage = _Stage.waiting;
    });
    _poll?.cancel();
    _poll = Timer.periodic(_pollEvery, (_) => _check());
  }

  /// Подключено ли уже. Связь мигнула — спросим в следующий раз.
  Future<void> _check() async {
    if (_checking || _stage != _Stage.waiting) return;
    final expiresAt = _expiresAt;
    if (expiresAt != null && DateTime.now().isAfter(expiresAt)) {
      _poll?.cancel();
      setState(() {
        _stage = _Stage.off;
        _url = null;
        _expired = true;
      });
      return;
    }
    _checking = true;
    try {
      final state = await fetchTelegramState();
      if (!mounted || _stage != _Stage.waiting || !state.linked) return;
      _poll?.cancel();
      setState(() {
        _stage = _Stage.linked;
        _url = null;
      });
      HapticFeedback.mediumImpact();
      _say('tg_linked_now'.tr);
    } catch (_) {
      // Не ответил — не беда: экран спросит снова через пару секунд.
    } finally {
      _checking = false;
    }
  }

  void _cancel() {
    _poll?.cancel();
    setState(() {
      _stage = _Stage.off;
      _url = null;
    });
  }

  Future<void> _copy() async {
    final url = _url;
    if (url == null) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) _say('tg_copied'.tr);
  }

  Future<void> _disconnect() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('tg_disconnect_q'.tr),
        content: Text('tg_disconnect_hint'.tr),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('cancel'.tr),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('tg_disconnect'.tr),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() => _busy = true);
    final (ok, problem) = await unlinkTelegram();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) {
        _stage = _Stage.off;
        _expired = false;
      }
    });
    _say(ok ? 'tg_disconnected'.tr : problemMessage(problem));
  }

  void _say(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('tg_title'.tr)),
      body: switch (_stage) {
        _Stage.loading => const Center(child: CircularProgressIndicator()),
        _Stage.failed => LoadErrorView(problem: _problem, onRetry: _load),
        _ => ListView(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
            children: _body(),
          ),
      },
    );
  }

  List<Widget> _body() {
    if (!_enabled) return [_text('tg_not_configured'.tr)];
    switch (_stage) {
      case _Stage.linked:
        return [
          _status(Icons.check_circle_outline, Colors.green.shade700,
              'tg_linked'.tr),
          const SizedBox(height: 14),
          _text('tg_linked_hint'.tr),
          const SizedBox(height: 10),
          _muted('tg_privacy'.tr),
          const SizedBox(height: 28),
          OutlinedButton.icon(
            onPressed: _busy ? null : _disconnect,
            icon: const Icon(Icons.notifications_off_outlined),
            label: Text('tg_disconnect'.tr),
          ),
        ];
      case _Stage.waiting:
        return [
          _text('tg_step'.tr),
          const SizedBox(height: 22),
          // Ссылка открывается прямо по касанию — иначе Safari её не откроет.
          FilledButton.icon(
            onPressed: () => openExternal(context, _url!),
            icon: const Icon(Icons.send),
            label: Text('tg_open'.tr),
          ),
          const SizedBox(height: 6),
          TextButton.icon(
            onPressed: _copy,
            icon: const Icon(Icons.copy, size: 18),
            label: Text('tg_copy'.tr),
          ),
          const SizedBox(height: 22),
          Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Expanded(child: _muted('tg_waiting'.tr)),
            ],
          ),
          const SizedBox(height: 10),
          _muted('tg_expires'
              .trParams({'minutes': '${_lifetime.inMinutes}'})),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: _cancel, child: Text('cancel'.tr)),
          ),
        ];
      default:
        return [
          _text('tg_intro'.tr),
          const SizedBox(height: 10),
          _muted('tg_privacy'.tr),
          if (_expired) ...[
            const SizedBox(height: 18),
            _status(Icons.timer_off_outlined, Colors.orange.shade800,
                'tg_expired'.tr),
          ],
          const SizedBox(height: 28),
          FilledButton.icon(
            onPressed: _busy ? null : _connect,
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.send),
            label: Text('tg_connect'.tr),
          ),
        ];
    }
  }

  Widget _text(String text) => Text(text,
      style: TextStyle(fontSize: 15, height: 1.45, color: context.inkColor));

  Widget _muted(String text) => Text(text,
      style: TextStyle(fontSize: 13, height: 1.4, color: context.mutedColor));

  Widget _status(IconData icon, Color color, String text) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 15,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                    color: color)),
          ),
        ],
      );
}
