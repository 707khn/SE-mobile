import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../requests/qr_login_request.dart';
import '../utils/app_theme.dart';
import '../utils/colors.dart';
import '../utils/open_in_safari.dart';
import '../utils/own_password.dart';
import '../utils/secure_storage_helper.dart';
import '../widgets/qr_camera.dart' show browserDescription;
import '../widgets/qr_view.dart';
import 'pin_screen.dart';

/// Вход на компьютере по QR-коду с телефона — как в WhatsApp и Telegram.
///
/// Компьютер показывает код, человек считывает его в SE-mobile на
/// телефоне («Настройки» → «Вход на компьютере») и подтверждает. Пароль на
/// компьютере не нужен: у большинства его и нет — на телефоне входят кодом
/// из четырёх цифр.
///
/// Код живёт две минуты; не дождавшись, экран сам берёт новый — несколько
/// раз, а дальше просит нажать кнопку, чтобы забытая на экране программа не
/// спрашивала сервер весь день.
///
/// [viaSafari] — то же для значка с экрана «Домой» на iPhone: свой вход
/// значок не получил (см. web_handoff_request.dart), а в Safari на этом же
/// телефоне человек уже вошёл. Код подтверждают там: кнопка открывает
/// Safari сразу на нужном экране. QR-кода нет — камерой свой же экран не
/// считать.
class QrLoginPcScreen extends StatefulWidget {
  const QrLoginPcScreen({super.key, this.viaSafari = false});

  final bool viaSafari;

  @override
  State<QrLoginPcScreen> createState() => _QrLoginPcScreenState();
}

enum _Stage { loading, waiting, scanned, rejected, stale, failed }

class _QrLoginPcScreenState extends State<QrLoginPcScreen> {
  static const _pollEvery = Duration(seconds: 2);

  /// Сколько раз подряд сменить код без нажатия: пять кодов — десять минут.
  static const _autoRenewals = 5;

  _Stage _stage = _Stage.loading;
  QrLoginTicket? _ticket;
  DateTime? _expiresAt;
  Timer? _timer;
  bool _polling = false;
  bool _offline = false;
  bool _done = false;
  int _renewals = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String get _deviceName {
    if (widget.viaSafari) return 'qr_safari_device'.tr;
    // Браузер имени компьютера не скажет — называемся браузером и системой.
    if (kIsWeb) return browserDescription();
    try {
      return Platform.localHostname;
    } catch (_) {
      return '';
    }
  }

  Future<void> _start({bool manual = false}) async {
    _timer?.cancel();
    if (manual) _renewals = 0;
    setState(() {
      _stage = _Stage.loading;
      _offline = false;
    });
    final ticket = await startQrLogin(_deviceName);
    if (!mounted) return;
    if (ticket == null) {
      setState(() => _stage = _Stage.failed);
      return;
    }
    setState(() {
      _ticket = ticket;
      _expiresAt = DateTime.now().add(ticket.lifetime);
      _stage = _Stage.waiting;
    });
    _timer = Timer.periodic(_pollEvery, (_) => _poll());
  }

  Future<void> _poll() async {
    final ticket = _ticket;
    if (_polling || _done || ticket == null) return;
    _polling = true;
    try {
      final result = await pollQrLogin(ticket.secret);
      if (!mounted || _done || ticket != _ticket) return;
      switch (result.status) {
        case QrPollStatus.waiting:
        case QrPollStatus.scanned:
          setState(() {
            _offline = false;
            _stage = result.status == QrPollStatus.scanned
                ? _Stage.scanned
                : _Stage.waiting;
          });
        case QrPollStatus.approved:
          _done = true;
          _timer?.cancel();
          await _enter(result.body!);
        case QrPollStatus.rejected:
          _timer?.cancel();
          setState(() => _stage = _Stage.rejected);
        case QrPollStatus.expired:
          _renew();
        case QrPollStatus.offline:
          // Связь мигнула — спросим снова. Код при этом мог и истечь.
          final expiresAt = _expiresAt;
          if (expiresAt != null && DateTime.now().isAfter(expiresAt)) {
            _renew();
          } else {
            setState(() => _offline = true);
          }
      }
    } finally {
      _polling = false;
    }
  }

  void _renew() {
    _timer?.cancel();
    if (_renewals >= _autoRenewals) {
      setState(() => _stage = _Stage.stale);
      return;
    }
    _renewals++;
    _start();
  }

  Future<void> _enter(Map<String, dynamic> body) async {
    final fullName = (body['full_name'] as String?) ?? '';
    final job = (body['job'] as String?) ?? '';
    await SecureStorageHelper.instance.saveCredentials(
      login: (body['login'] as String?) ?? '',
      fullName: fullName,
      job: job,
      employeeId: (body['employee_id'] as String?) ?? '',
      token: body['token'] as String?,
    );
    final hasPassword = body['has_password'];
    if (hasPassword is bool) await OwnPassword.save(hasPassword);
    // Дальше — как после входа паролем: код из четырёх цифр для этого
    // компьютера, если его ещё нет, и приложение.
    await enterApp(fullName: fullName, job: job);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(
              widget.viaSafari ? 'qr_safari_title'.tr : 'qr_pc_title'.tr)),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _codeBox(context),
                const SizedBox(height: 24),
                _steps(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _codeBox(BuildContext context) {
    const size = 260.0;
    final ticket = _ticket;
    final Widget inner;
    switch (_stage) {
      case _Stage.loading:
        inner = const SizedBox.square(
            dimension: size,
            child: Center(child: CircularProgressIndicator()));
      case _Stage.waiting:
        inner = Column(mainAxisSize: MainAxisSize.min, children: [
          if (!widget.viaSafari) ...[
            QrView(data: qrLoginLink(ticket!.code), size: size),
            const SizedBox(height: 12),
          ],
          SelectableText(
            qrLoginCodeForEyes(ticket!.code),
            style: TextStyle(
              fontSize: 22,
              letterSpacing: 4,
              fontWeight: FontWeight.w600,
              color: context.inkColor,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 4),
          if (widget.viaSafari) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => openInSafari(qrLoginLink(ticket.code)),
              icon: const Icon(Icons.open_in_new),
              label: Text('qr_safari_open'.tr),
            ),
          ] else
            Text('qr_pc_code_hint'.tr,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: context.mutedColor)),
          if (_offline) ...[
            const SizedBox(height: 8),
            Text('qr_pc_offline'.tr,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12.5, color: Colors.orange)),
          ],
        ]);
      case _Stage.scanned:
        inner = _message(
          context,
          icon: Icons.phone_android,
          title: widget.viaSafari ? 'qr_safari_scanned'.tr : 'qr_pc_scanned'.tr,
          hint: widget.viaSafari
              ? 'qr_safari_scanned_hint'.tr
              : 'qr_pc_scanned_hint'.tr,
          busy: true,
        );
      case _Stage.rejected:
        inner = _message(
          context,
          icon: Icons.block,
          title: 'qr_pc_rejected'.tr,
          hint: 'qr_pc_rejected_hint'.tr,
          action: 'qr_pc_new_code'.tr,
        );
      case _Stage.stale:
        inner = _message(
          context,
          icon: Icons.timer_off_outlined,
          title: 'qr_pc_stale'.tr,
          hint: 'qr_pc_stale_hint'.tr,
          action: 'qr_pc_new_code'.tr,
        );
      case _Stage.failed:
        inner = _message(
          context,
          icon: Icons.cloud_off,
          title: 'qr_pc_failed'.tr,
          hint: 'qr_pc_failed_hint'.tr,
          action: 'qr_pc_retry'.tr,
        );
    }
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 16, offset: Offset(0, 6))
        ],
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: KeyedSubtree(key: ValueKey(_stage), child: inner),
      ),
    );
  }

  Widget _message(BuildContext context,
      {required IconData icon,
      required String title,
      required String hint,
      String? action,
      bool busy = false}) {
    return SizedBox(
      width: 260,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 24),
          Icon(icon, size: 56, color: AppColors.mainColor),
          const SizedBox(height: 16),
          Text(title,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: context.inkColor)),
          const SizedBox(height: 8),
          Text(hint,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13.5, height: 1.4, color: context.mutedColor)),
          const SizedBox(height: 20),
          if (busy) const CircularProgressIndicator(),
          if (action != null)
            FilledButton.icon(
              onPressed: () => _start(manual: true),
              icon: const Icon(Icons.refresh),
              label: Text(action),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _steps(BuildContext context) {
    final steps = widget.viaSafari
        ? ['qr_safari_step1'.tr, 'qr_safari_step2'.tr, 'qr_safari_step3'.tr]
        : ['qr_pc_step1'.tr, 'qr_pc_step2'.tr, 'qr_pc_step3'.tr];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < steps.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 13,
                  backgroundColor: AppColors.mainColor,
                  child: Text('${i + 1}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(steps[i],
                        style: TextStyle(
                            fontSize: 15, height: 1.35, color: context.inkColor)),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Text(widget.viaSafari ? 'qr_safari_safety'.tr : 'qr_pc_safety'.tr,
            style: TextStyle(
                fontSize: 12.5, height: 1.4, color: context.mutedColor)),
      ],
    );
  }
}
