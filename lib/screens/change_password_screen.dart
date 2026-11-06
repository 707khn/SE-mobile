import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../requests/account_request.dart';
import '../utils/colors.dart';
import '../utils/dimensions.dart';
import '../utils/logout_helper.dart';
import '../utils/secure_storage_helper.dart';
import 'pin_screen.dart';
import '../utils/app_theme.dart';
import '../utils/login_lock.dart';
import '../widgets/load_error_view.dart';

/// Экран «придумайте пароль».
///
/// Показывается сразу после входа с компьютера, если пароль временный —
/// выданный код или табельный номер. Пропустить его нельзя: пока пароль
/// выданный, учётная запись открыта любому, кто его знает. На телефоне и в
/// браузере выданный пароль вместо этого гасят (см. settleIssuedPassword), а
/// сюда попадают, только если сервер не согласился.
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({
    Key? key,
    required this.fullName,
    required this.job,
    required this.currentPassword,
    this.mandatory = true,
    this.hasPassword = true,
  }) : super(key: key);

  final String fullName;
  final String job;

  /// Текущий пароль. При обязательной смене сразу после входа он известен —
  /// человек только что им вошёл, и спрашивать второй раз незачем. А вот
  /// когда пароль сбросили, пока человек пользовался кодом, известен он
  /// только самому человеку: тогда пусто, и поле показываем.
  final String currentPassword;

  /// false — человек пришёл сюда сам из меню и может уйти.
  final bool mandatory;

  /// false — своего пароля нет: человек вошёл с телефона или из браузера по
  /// одноразовому коду и задаёт пароль для входа с компьютера. Старого
  /// спрашивать не о чем, поэтому вместо него — код из четырёх цифр:
  /// открытый чужой телефон не должен позволить завести пароль и входить
  /// потом откуда угодно.
  final bool hasPassword;

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _oldController = TextEditingController();
  final _newController = TextEditingController();
  final _repeatController = TextEditingController();

  bool _obscureNew = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.mandatory) _oldController.text = widget.currentPassword;
  }

  /// Пароля нет — вместо старого спрашиваем код для входа в приложение.
  bool get _askPin => !widget.mandatory && !widget.hasPassword;

  /// Код из четырёх цифр под тем же счётчиком, что и на экране кода: пятая
  /// ошибка выводит из учётной записи.
  Future<bool> _pinMatches() async {
    final secure = SecureStorageHelper.instance;
    final saved = await secure.getPin();
    if (saved == null) return true;
    if (_oldController.text.trim() == saved) {
      await secure.resetPinFails();
      return true;
    }
    final fails = await secure.bumpPinFails();
    if (!mounted) return false;
    if (fails >= pinMaxFails) {
      await forceLogout(message: 'pin_locked_out'.tr);
      return false;
    }
    _oldController.clear();
    setState(() => _error = '${'pin_wrong'.tr}. ${'pin_attempts_left'.trParams(
        {'count': '${pinMaxFails - fails}'})}');
    return false;
  }

  @override
  void dispose() {
    _oldController.dispose();
    _newController.dispose();
    _repeatController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final fresh = _newController.text.trim();
    if (fresh != _repeatController.text.trim()) {
      setState(() => _error = 'password_mismatch'.tr);
      return;
    }
    if (_askPin && !await _pinMatches()) return;
    setState(() {
      _saving = true;
      _error = null;
    });

    final (result, problem, retryAfter) = await changePassword(
      oldPassword: _askPin ? '' : _oldController.text.trim(),
      newPassword: fresh,
    );
    if (!mounted) return;
    setState(() => _saving = false);

    switch (result) {
      case PasswordChangeResult.ok:
        HapticFeedback.mediumImpact();
        Get.snackbar(
          'password_changed'.tr,
          'password_changed_body'.tr,
          snackPosition: SnackPosition.BOTTOM,
          margin: const EdgeInsets.all(12),
        );
        if (widget.mandatory) {
          await SecureStorageHelper.instance.clearPasswordExpired();
          await enterApp(fullName: widget.fullName, job: widget.job);
        } else {
          Get.back();
        }
        break;
      case PasswordChangeResult.wrongOldPassword:
        setState(() => _error = 'password_old_wrong'.tr);
        break;
      case PasswordChangeResult.tooShort:
        setState(() => _error = 'password_too_short'.tr);
        break;
      case PasswordChangeResult.sameAsLogin:
        setState(() => _error = 'password_same_as_login'.tr);
        break;
      case PasswordChangeResult.tooSimple:
        setState(() => _error = 'password_too_simple'.tr);
        break;
      case PasswordChangeResult.locked:
        final minutes = lockMinutes(retryAfter);
        setState(() => _error = minutes == null
            ? 'login_locked_soon'.tr
            : 'login_locked_wait'.trParams({'minutes': '$minutes'}));
        break;
      case PasswordChangeResult.noAccount:
      case PasswordChangeResult.networkError:
        // Раньше здесь всегда было «Ошибка подключения к серверу» — и когда
        // сети нет, и когда сервер ответил ошибкой.
        setState(() => _error = problemMessage(problem));
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Обязательную смену нельзя обойти системной кнопкой «назад»: иначе
    // человек окажется в приложении с паролем, равным табельному номеру.
    return PopScope(
      canPop: !widget.mandatory,
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: !widget.mandatory,
          title: Text(widget.hasPassword
              ? 'password_change_title'.tr
              : 'password_set_title'.tr),
          actions: [
            if (widget.mandatory)
              TextButton(
                onPressed: () => confirmAndLogout(context),
                child: Text('log_out_title'.tr,
                    style: const TextStyle(color: Colors.white)),
              ),
          ],
        ),
        body: SingleChildScrollView(
          padding: EdgeInsets.all(Dimensions.width20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.mandatory || _askPin) _buildWhy(),
              if (widget.mandatory || _askPin)
                SizedBox(height: Dimensions.height30 / 1.5),
              if (!widget.mandatory || widget.currentPassword.isEmpty) ...[
                _field(
                  controller: _oldController,
                  label: _askPin ? 'password_pin_field'.tr : 'password_old'.tr,
                  obscure: true,
                  digits: _askPin,
                ),
                const SizedBox(height: 14),
              ],
              _field(
                controller: _newController,
                label: 'password_new'.tr,
                obscure: _obscureNew,
                trailing: IconButton(
                  icon: Icon(_obscureNew ? Icons.visibility_off : Icons.visibility,
                      size: 20),
                  onPressed: () => setState(() => _obscureNew = !_obscureNew),
                ),
              ),
              const SizedBox(height: 14),
              _field(
                controller: _repeatController,
                label: 'password_repeat'.tr,
                obscure: _obscureNew,
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 10),
              Text(
                'password_rules'.tr,
                style: TextStyle(fontSize: 12, color: context.mutedColor),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(Icons.error_outline, size: 18, color: Colors.red.shade700),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_error!,
                          style: TextStyle(color: Colors.red.shade700, fontSize: 13)),
                    ),
                  ],
                ),
              ],
              SizedBox(height: Dimensions.height30),
              SizedBox(
                height: 48,
                child: ElevatedButton(
                  onPressed: _saving ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.mainColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: _saving
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : Text('save'.tr,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWhy() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.mainColor.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline, color: context.accentColor, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _askPin
                  ? 'password_set_why'.tr
                  : widget.currentPassword.isEmpty
                      ? 'password_change_why_reset'.tr
                      : 'password_change_why'.tr,
              style: const TextStyle(fontSize: 13.5, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required bool obscure,
    Widget? trailing,
    ValueChanged<String>? onSubmitted,
    bool digits = false,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType:
          digits ? TextInputType.number : TextInputType.visiblePassword,
      maxLength: digits ? 4 : null,
      inputFormatters:
          digits ? [FilteringTextInputFormatter.digitsOnly] : null,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: trailing,
        filled: true,
        fillColor: context.cardSurface,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: context.hairlineColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: context.accentColor, width: 2),
        ),
      ),
    );
  }
}
