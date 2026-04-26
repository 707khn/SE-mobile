import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:se_mobile/requests/login_request.dart';
import '../screens/start_screen.dart';
import '../utils/colors.dart';
import '../utils/dimensions.dart';

class LoginButton extends StatefulWidget {
  const LoginButton({Key? key, required this.inButton}) : super(key: key);

  final Widget inButton;

  @override
  State<LoginButton> createState() => _LoginButtonState();
}

class _LoginButtonState extends State<LoginButton> {
  bool _loading = false;

  final loginController = CustomFormState.loginController;

  @override
  Widget build(BuildContext context) {
    return Container(
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
        onPressed: _loading ? null : _submit,
        child: _loading
            ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            : widget.inButton,
      ),
    );
  }

  Future<void> _submit() async {
    final login = loginController.text.trim();
    if (login.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('login_empty'.tr),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    setState(() => _loading = true);
    await loginToAccount(login, context);
    if (mounted) setState(() => _loading = false);
  }
}
