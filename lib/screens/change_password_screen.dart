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
import '../widgets/load_error_view.dart';

/// Экран «придумайте пароль».
///
/// Показывается сразу после входа, если пароль временный — то есть равен
/// табельному номеру. Пропустить его нельзя: пока пароль совпадает с номером,
/// учётная запись открыта любому, кто этот номер знает.
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({
    Key? key,
    required this.fullName,
    required this.job,
    required this.currentPassword,
    this.mandatory = true,
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
    setState(() {
      _saving = true;
      _error = null;
    });

    final (result, problem) = await changePassword(
      oldPassword: _oldController.text.trim(),
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
          title: Text('password_change_title'.tr),
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
              if (widget.mandatory) _buildWhy(),
              if (widget.mandatory) SizedBox(height: Dimensions.height30 / 1.5),
              if (!widget.mandatory || widget.currentPassword.isEmpty) ...[
                _field(
                  controller: _oldController,
                  label: 'password_old'.tr,
                  obscure: true,
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
              widget.currentPassword.isEmpty
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
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: TextInputType.visiblePassword,
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
