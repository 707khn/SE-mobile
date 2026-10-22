import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/app_theme.dart';
import '../utils/app_update.dart';
import '../utils/app_version.dart';
import '../utils/colors.dart';
import '../utils/open_external.dart';

/// Не пускает дальше экрана «Нужно обновить», если сборка устарела.
///
/// Стоит над всем приложением, а не на одном экране: устаревшую сборку
/// нельзя пройти ни через вход, ни через код, ни через уведомление.
/// Само приложение под экраном остаётся живым, только скрытым, — снимет
/// администратор ограничение, и человек вернётся туда же, где был.
///
/// Спрашивает сервер при запуске и при возвращении из фона: приложение
/// неделями висит в памяти, и узнать о новой минимальной сборке только при
/// перезапуске значило бы узнать о ней через неделю.
class UpdateGate extends StatefulWidget {
  const UpdateGate({Key? key, required this.prefs, required this.child})
      : super(key: key);

  final SharedPreferences prefs;
  final Widget child;

  @override
  State<UpdateGate> createState() => _UpdateGateState();
}

class _UpdateGateState extends State<UpdateGate> with WidgetsBindingObserver {
  late UpdateStatus _status;
  DateTime? _askedAt;
  bool _checking = false;

  /// Чаще незачем: минимальную сборку поднимают раз в несколько недель.
  static const Duration _every = Duration(minutes: 30);

  @override
  void initState() {
    super.initState();
    _status = UpdateStatus.remembered(widget.prefs);
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final asked = _askedAt;
    // Тот, кто уже упёрся в экран, только что ходил ставить обновление —
    // ему ответ нужен сразу, без получасовой паузы.
    if (_status.required ||
        asked == null ||
        DateTime.now().difference(asked) > _every) {
      unawaited(_refresh());
    }
  }

  Future<void> _refresh() async {
    if (_checking) return;
    _checking = true;
    if (mounted) setState(() {});
    final fresh = await UpdateStatus.fetch();
    _checking = false;
    if (!mounted) return;
    setState(() {
      if (fresh != null) {
        _status = fresh;
        _askedAt = DateTime.now();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_status.required) return widget.child;
    return Stack(
      children: [
        // Навигатор остаётся в дереве: замок по коду и уведомления ходят
        // через него, и без него они бы падали.
        Offstage(child: TickerMode(enabled: false, child: widget.child)),
        Positioned.fill(
          child: UpdateRequiredScreen(
            status: _status,
            checking: _checking,
            onRetry: _refresh,
          ),
        ),
      ],
    );
  }
}

/// Экран «Нужно обновить приложение».
class UpdateRequiredScreen extends StatelessWidget {
  const UpdateRequiredScreen({
    Key? key,
    required this.status,
    required this.checking,
    required this.onRetry,
  }) : super(key: key);

  final UpdateStatus status;
  final bool checking;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final update = status.latest;
    return Scaffold(
      backgroundColor: context.pageColor,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.system_update_outlined,
                    size: 64, color: AppColors.mainColor),
                const SizedBox(height: 20),
                Text('update_required_title'.tr,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: context.inkColor)),
                const SizedBox(height: 12),
                Text(
                  'update_required_text'
                      .trParams({'version': appVersionLabel()}),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 15, height: 1.4, color: context.mutedColor),
                ),
                const SizedBox(height: 28),
                if (update != null) ...[
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.mainColor,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      icon: const Icon(Icons.download_outlined),
                      label: Text(
                        update.sizeLabel.isEmpty
                            ? '${'update_download'.tr} ${update.label}'
                            : '${'update_download'.tr} ${update.label} · ${update.sizeLabel}',
                        style: const TextStyle(fontSize: 15),
                      ),
                      onPressed: () => openExternal(context, update.url),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text('update_hint'.tr,
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(fontSize: 13, color: context.mutedColor)),
                ] else
                  Text('update_required_no_file'.tr,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 14, height: 1.4, color: context.inkColor)),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: checking ? null : onRetry,
                  child: checking
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text('update_required_retry'.tr),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
