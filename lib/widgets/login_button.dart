import 'package:flutter/material.dart';
import 'package:se_mobile/requests/login_request.dart';
import '../screens/start_screen.dart';
import '../utils/colors.dart';
import '../utils/dimensions.dart';

class LoginButton extends StatelessWidget {
  LoginButton({Key? key, required this.inButton}) : super(key: key);

  final dynamic inButton;
  final loginController = CustomFormState.loginController;
  final passwordController = CustomFormState.passwordController;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [
            AppColors.gradientColor1,
            AppColors.gradientColor2,
          ],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        borderRadius: BorderRadius.all(
          Radius.circular(Dimensions.radius25),
        ),
        border: Border.all(
          color: AppColors.mainColor, // Цвет границы
          width: 1.5, // Толщина границы
        ),
      ),
      child: TextButton(
        style: TextButton.styleFrom(
          primary: Theme
              .of(context)
              .colorScheme
              .onPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(
              Radius.circular(Dimensions.radius25),
            ),
          ),
          minimumSize: Size(Dimensions.width120 * 1.2, Dimensions.height30),
        ),
        onPressed: () {
          String login = loginController.text;
          loginToAccount(login, context);
        },
        child: inButton,
      ),
    );
  }
}