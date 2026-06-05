import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:se_mobile/requests/login_request.dart';
import '../screens/start_screen.dart';
import '../utils/colors.dart';
import '../utils/dimensions.dart';

class LoginButton extends StatefulWidget {
  const LoginButton({Key? key, required this.inButton}) : super(key: key);

  final Widget inButton;

  @override
  LoginButtonState createState() => LoginButtonState();
}

class LoginButtonState extends State<LoginButton> with SingleTickerProviderStateMixin {
  bool _loading = false;
  late AnimationController _shakeController;

  @override
  void initState() {
    super.initState();
    _shakeController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
  }

  @override
  void dispose() {
    _shakeController.dispose();
    super.dispose();
  }

  final loginController = CustomFormState.loginController;
  final passwordController = CustomFormState.passwordController;

  Future<void> submit() async {
    final login = loginController.text.trim();
    final password = passwordController.text.trim();
    if (login.isEmpty) {
      HapticFeedback.mediumImpact();
      _shakeController.forward(from: 0);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('login_empty'.tr), behavior: SnackBarBehavior.floating),
      );
      return;
    }
    if (password.isEmpty) {
      HapticFeedback.mediumImpact();
      _shakeController.forward(from: 0);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('password_empty'.tr), behavior: SnackBarBehavior.floating),
      );
      return;
    }
    HapticFeedback.lightImpact();
    setState(() => _loading = true);
    await loginToAccount(login, password, context);
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _shakeController,
      builder: (context, child) {
        final sineValue = sin(_shakeController.value * pi * 8);
        return Transform.translate(
          offset: Offset(sineValue * 6 * (1 - _shakeController.value), 0),
          child: child,
        );
      },
      child: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [AppColors.gradientColor1, AppColors.gradientColor2],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ),
          borderRadius: BorderRadius.all(Radius.circular(Dimensions.radius25)),
          border: Border.all(color: AppColors.mainColor, width: 1.5),
        ),
        child: TextButton(
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.onPrimary,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(Dimensions.radius25)),
            ),
            minimumSize: Size(Dimensions.width120 * 1.2, Dimensions.height30),
          ),
          onPressed: _loading ? null : submit,
          child: _loading
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : widget.inButton,
        ),
      ),
    );
  }
}
