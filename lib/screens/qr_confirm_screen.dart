import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../requests/qr_login_request.dart';
import '../utils/api.dart';
import '../utils/app_theme.dart';
import '../utils/colors.dart';
import '../widgets/qr_camera.dart';

/// «Вход на компьютере»: считать QR-код с экрана компьютера и подтвердить.
///
/// Телефон здесь — ключ: человек на нём уже вошёл (и открыл его своим
/// кодом из четырёх цифр), и только с него можно впустить компьютер.
/// Поэтому прежде чем впустить, экран говорит, какой компьютер просится, и
/// предупреждает: код, который прислали или попросили считать, —
/// это попытка украсть доступ.
class QrConfirmScreen extends StatefulWidget {
  const QrConfirmScreen({super.key, this.initialCode});

  /// Код из ссылки, по которой открыли веб-версию (…/web/?pc=…).
  final String? initialCode;

  @override
  State<QrConfirmScreen> createState() => _QrConfirmScreenState();
}

enum _Stage { scan, manual, checking, confirm, sending, done }

class _QrConfirmScreenState extends State<QrConfirmScreen> {
  late _Stage _stage = qrCameraSupported ? _Stage.scan : _Stage.manual;
  final _input = TextEditingController();
  String? _code;
  String _device = '';
  String? _error;
  int _cameraKey = 0;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialCode;
    if (initial != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _check(initial));
    }
  }

  @override
  void dispose() {
    // Ушли с вопроса «впустить?», не ответив, — значит, нет: компьютер
    // сразу узнает об отказе, а не будет ждать две минуты.
    final code = _code;
    if (_stage == _Stage.confirm && code != null) {
      answerQrLogin(code, approve: false);
    }
    _input.dispose();
    super.dispose();
  }

  Future<void> _check(String raw) async {
    final code = qrLoginCodeFrom(raw);
    if (code == null) {
      setState(() {
        _error = 'qr_bad_code'.tr;
        _cameraKey++;
      });
      return;
    }
    final back = _stage == _Stage.manual || !qrCameraSupported
        ? _Stage.manual
        : _Stage.scan;
    setState(() {
      _stage = _Stage.checking;
      _error = null;
    });
    final (answer, device) = await scanQrLogin(code);
    if (!mounted) return;
    if (answer == QrAnswer.ok) {
      HapticFeedback.mediumImpact();
      setState(() {
        _code = code;
        _device = device;
        _stage = _Stage.confirm;
      });
      return;
    }
    if (answer == QrAnswer.unauthorized) {
      await returnToLogin();
      return;
    }
    setState(() {
      _stage = back;
      _cameraKey++;
      _error = _errorText(answer);
    });
  }

  String _errorText(QrAnswer answer) => switch (answer) {
        QrAnswer.notFound => 'qr_not_found'.tr,
        QrAnswer.taken => 'qr_taken'.tr,
        _ => 'qr_offline'.tr,
      };

  Future<void> _answer(bool approve) async {
    final code = _code;
    if (code == null) return;
    setState(() => _stage = _Stage.sending);
    final answer = await answerQrLogin(code, approve: approve);
    if (!mounted) return;
    if (answer == QrAnswer.unauthorized) {
      await returnToLogin();
      return;
    }
    if (!approve) {
      _code = null;
      Get.back();
      return;
    }
    if (answer == QrAnswer.ok) {
      HapticFeedback.mediumImpact();
      setState(() {
        _code = null;
        _stage = _Stage.done;
      });
      return;
    }
    setState(() {
      _code = null;
      _stage = qrCameraSupported ? _Stage.scan : _Stage.manual;
      _cameraKey++;
      _error = _errorText(answer);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('qr_phone_title'.tr)),
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: KeyedSubtree(
            key: ValueKey(_stage),
            child: switch (_stage) {
              _Stage.scan => _scan(context),
              _Stage.manual => _manual(context),
              _Stage.checking ||
              _Stage.sending =>
                const Center(child: CircularProgressIndicator()),
              _Stage.confirm => _confirm(context),
              _Stage.done => _done(context),
            },
          ),
        ),
      ),
    );
  }

  Widget _errorLine() {
    final error = _error;
    if (error == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(error,
            style: const TextStyle(color: Color(0xFFC62828), fontSize: 14)),
      ),
    );
  }

  Widget _scan(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('qr_phone_scan_hint'.tr,
            style: TextStyle(fontSize: 15, height: 1.4, color: context.inkColor)),
        const SizedBox(height: 16),
        _errorLine(),
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: AspectRatio(
            aspectRatio: 1,
            child: QrCamera(
              key: ValueKey(_cameraKey),
              onCode: _check,
              onProblem: (problem) {
                if (!mounted) return;
                setState(() {
                  _stage = _Stage.manual;
                  _error = problem == QrCameraProblem.denied
                      ? 'qr_camera_denied'.tr
                      : 'qr_camera_unavailable'.tr;
                });
              },
            ),
          ),
        ),
        const SizedBox(height: 16),
        TextButton.icon(
          onPressed: () => setState(() {
            _stage = _Stage.manual;
            _error = null;
          }),
          icon: const Icon(Icons.keyboard_outlined),
          label: Text('qr_type_code'.tr),
        ),
      ],
    );
  }

  Widget _manual(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('qr_phone_manual_hint'.tr,
            style: TextStyle(fontSize: 15, height: 1.4, color: context.inkColor)),
        const SizedBox(height: 16),
        _errorLine(),
        TextField(
          controller: _input,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          autocorrect: false,
          enableSuggestions: false,
          maxLength: 9,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 24, letterSpacing: 4),
          decoration: const InputDecoration(
            hintText: 'ABCD 2345',
            border: OutlineInputBorder(),
            counterText: '',
          ),
          onSubmitted: _check,
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () => _check(_input.text),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text('qr_next'.tr),
          ),
        ),
        if (qrCameraSupported) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () => setState(() {
              _stage = _Stage.scan;
              _error = null;
              _cameraKey++;
            }),
            icon: const Icon(Icons.qr_code_scanner),
            label: Text('qr_use_camera'.tr),
          ),
        ],
      ],
    );
  }

  Widget _confirm(BuildContext context) {
    final device = _device.isEmpty ? 'qr_device_unknown'.tr : _device;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const SizedBox(height: 12),
        const Icon(Icons.computer, size: 64, color: AppColors.mainColor),
        const SizedBox(height: 16),
        Text('qr_confirm_title'.tr,
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: context.inkColor)),
        const SizedBox(height: 8),
        Text('qr_confirm_device'.trParams({'device': device}),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, color: context.mutedColor)),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.orange.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.warning_amber_rounded, color: Colors.orange),
              const SizedBox(width: 10),
              Expanded(
                child: Text('qr_confirm_warning'.tr,
                    style: TextStyle(
                        fontSize: 14, height: 1.4, color: context.inkColor)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () => _answer(true),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text('qr_confirm_yes'.tr),
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () => _answer(false),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text('cancel'.tr),
          ),
        ),
      ],
    );
  }

  Widget _done(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle, size: 72, color: AppColors.mainColor),
            const SizedBox(height: 16),
            Text('qr_done'.tr,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: context.inkColor)),
            const SizedBox(height: 8),
            Text('qr_done_hint'.tr,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 14, height: 1.4, color: context.mutedColor)),
            const SizedBox(height: 24),
            FilledButton(onPressed: Get.back, child: Text('ok'.tr)),
          ],
        ),
      ),
    );
  }
}
