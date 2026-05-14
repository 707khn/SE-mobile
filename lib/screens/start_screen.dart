import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/colors.dart';
import '../utils/dimensions.dart';
import '../utils/secure_storage_helper.dart';
import '../utils/variables.dart';
import '../widgets/custom_login_field.dart';
import '../widgets/custom_text.dart';
import '../widgets/login_button.dart';


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

  static String _lang = "";
  late SharedPreferences prefs;

  @override
  void initState() {
    super.initState();
    _initPrefs();
  }

  Future<void> _initPrefs() async {
    prefs = await SharedPreferences.getInstance();
    if (prefs.getString(AppValues.LANG) == null) {
      prefs.setString(AppValues.LANG, "KZ");
    }
    setState(() {
      _lang = prefs.getString(AppValues.LANG)!;
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
            color: AppColors.niceWhite,
            boxShadow: const [
              BoxShadow(
                color: Colors.black87,
                offset: Offset(0, 0),
                blurRadius: 20,
                spreadRadius: 3,
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
                  child: _lang == "KZ"
                      ? SizedBox(
                          width: Dimensions.width20 * 1.25,
                          height: Dimensions.height30 * 1.25,
                          child: Image.asset('assets/ru.png'),
                        )
                      : SizedBox(
                          width: Dimensions.width20 * 1.25,
                          height: Dimensions.height30 * 1.25,
                          child: Image.asset('assets/kz.png'),
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
                hintText: 'employee ID'.tr,
                obscureText: false,
                controller: loginController,
                fontSize: Dimensions.fontSize20,
                backgroundColor: AppColors.loginField,
                onSubmitted: () => _loginButtonKey.currentState?.submit(),
              ),
              const SizedBox(height: 4),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: loginController,
                builder: (_, val, __) {
                  final len = val.text.length;
                  final done = len == 12;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          '$len / 12',
                          style: TextStyle(
                            fontSize: 12,
                            color: done ? AppColors.mainColor : Colors.grey.shade500,
                            fontWeight: done ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              SizedBox(height: Dimensions.height30),
              LoginButton(
                key: _loginButtonKey,
                inButton: BigText(
                  fontWeight: FontWeight.bold,
                  overflow: TextOverflow.visible,
                  content: "log in".tr,
                  color: AppColors.niceWhite,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  _changeLanguage() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    if (_lang == "KZ") {
      prefs.setString(AppValues.LANG, "RU");
      Get.updateLocale(Locale(prefs.getString(AppValues.LANG)!));
      setState(() => _lang = prefs.getString(AppValues.LANG)!);
    } else if (_lang == "RU") {
      prefs.setString(AppValues.LANG, "KZ");
      Get.updateLocale(Locale(prefs.getString(AppValues.LANG)!));
      setState(() => _lang = prefs.getString(AppValues.LANG)!);
    }
  }
}
