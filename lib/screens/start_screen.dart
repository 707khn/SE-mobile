import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../requests/login_request.dart';
import '../utils/colors.dart';
import '../utils/dimensions.dart';
import '../utils/secure_storage_helper.dart';
import '../utils/lang.dart';
import '../utils/variables.dart';
import '../widgets/custom_login_field.dart';
import '../widgets/custom_text.dart';
import '../widgets/login_button.dart';
import '../utils/app_theme.dart';


class StartPage extends StatelessWidget {
  const StartPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: null,
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: const CustomForm(),
      ),
    );
  }
}

class CustomForm extends StatefulWidget {
  const CustomForm({Key? key}) : super(key: key);

  @override
  CustomFormState createState() => CustomFormState();
}

class CustomFormState extends State<CustomForm> {
  static TextEditingController loginController = TextEditingController();
  static TextEditingController passwordController = TextEditingController();

  final _loginButtonKey = GlobalKey<LoginButtonState>();
  final _passwordFocus = FocusNode();

  static String _lang = "";
  late SharedPreferences prefs;

  @override
  void dispose() {
    _passwordFocus.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _initPrefs();
    // Пока человек набирает логин, сервер уже просыпается: на бесплатном
    // тарифе он засыпает и первый запрос иначе ждёт 40–60 секунд.
    warmUpServer();
  }

  Future<void> _initPrefs() async {
    prefs = await SharedPreferences.getInstance();
    if (prefs.getString(AppValues.LANG) == null) {
      prefs.setString(AppValues.LANG, Lang.ru);
    }
    setState(() {
      _lang = Lang.code(prefs.getString(AppValues.LANG));
    });
    final savedLogin = await SecureStorageHelper.instance.getLogin();
    if (savedLogin != null && savedLogin.isNotEmpty && loginController.text.isEmpty) {
      loginController.text = savedLogin;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        image: DecorationImage(
          image: AssetImage('assets/background.png'),
          fit: BoxFit.cover,
        ),
      ),
      child: SingleChildScrollView(
        child: Container(
          margin: EdgeInsets.symmetric(horizontal: Dimensions.width20),
          padding: EdgeInsets.symmetric(
            horizontal: Dimensions.width20,
            vertical: Dimensions.height30,
          ),
          decoration: BoxDecoration(
            color: context.cardSurface,
            boxShadow: const [
              BoxShadow(
                color: Colors.black38,
                offset: Offset(0, 8),
                blurRadius: 24,
              )
            ],
            borderRadius: BorderRadius.all(Radius.circular(Dimensions.radius25 * 0.8)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: GestureDetector(
                  onTap: _changeLanguage,
                  // The flag shows the language you switch *to*, so the caption
                  // names that same language rather than the current one.
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: Dimensions.width20 * 1.25,
                        height: Dimensions.height30 * 1.25,
                        child: Image.asset(
                            Lang.isKazakh(_lang) ? 'assets/ru.png' : 'assets/kz.png'),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        Lang.isKazakh(_lang) ? 'RU' : 'KZ',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: context.mutedColor,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: Dimensions.height30 / 2),
              SizedBox(
                height: Dimensions.height100 * 1.3,
                child: Image.asset('assets/logo.png'),
              ),
              SizedBox(height: Dimensions.height30),
              CustomLoginField(
                hintText: 'login'.tr,
                obscureText: false,
                controller: loginController,
                fontSize: Dimensions.fontSize20,
                // Most logins are tabular numbers, but "admin" is letters —
                // the text keyboard covers both.
                keyboardType: TextInputType.text,
                maxLength: 20,
                textInputAction: TextInputAction.next,
                onSubmitted: () => _passwordFocus.requestFocus(),
              ),
              SizedBox(height: Dimensions.height30 / 3),
              CustomLoginField(
                hintText: 'password'.tr,
                obscureText: true,
                controller: passwordController,
                fontSize: Dimensions.fontSize20,
                keyboardType: TextInputType.visiblePassword,
                maxLength: 50,
                focusNode: _passwordFocus,
                onSubmitted: () => _loginButtonKey.currentState?.submit(),
              ),
              SizedBox(height: Dimensions.height30),
              SizedBox(
                width: double.infinity,
                child: LoginButton(
                  key: _loginButtonKey,
                  inButton: BigText(
                    fontWeight: FontWeight.bold,
                    overflow: TextOverflow.visible,
                    content: "log in".tr,
                    color: AppColors.niceWhite,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  _changeLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    final next = Lang.isKazakh(_lang) ? Lang.ru : Lang.kk;
    await prefs.setString(AppValues.LANG, next);
    Get.updateLocale(Locale(next));
    if (mounted) setState(() => _lang = next);
  }
}
