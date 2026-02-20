import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/colors.dart';
import '../utils/dimensions.dart';
import '../utils/variables.dart';
import '../widgets/custom_login_field.dart';
import '../widgets/custom_text.dart';
import '../widgets/login_button.dart';


class StartPage extends StatelessWidget {
  const StartPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
        appBar: null,
        body: CustomForm());
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

  static String _lang = "";
  late SharedPreferences prefs;

  @override
  void initState() {
    super.initState();
    initializeSharedPreferences();
    loginController.addListener(_onLoginTextChanged);
  }

  void _onLoginTextChanged() {
    final text = loginController.text;
    loginController.value = loginController.value.copyWith(
      text: text.toUpperCase(),
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  Future<void> initializeSharedPreferences() async {
    prefs = await SharedPreferences.getInstance();
    if (prefs.getString(AppValues.LANG) == null) {
      prefs.setString(AppValues.LANG, "KZ");
    }
    setState(() {
      _lang = prefs.getString(AppValues.LANG)!;
    });
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
      child: Container(
        height: Dimensions.height120*3,
        width: Dimensions.width120*2.6,
        decoration: BoxDecoration(color: AppColors.niceWhite,
          boxShadow:const [
            BoxShadow(
              color: Colors.black87,
              offset: Offset(0,0),
              blurRadius: 20,
              spreadRadius: 3,
            )
          ],
          borderRadius:
          BorderRadius.all(Radius.circular((Dimensions.radius25*0.8))),
        ),
        child: Column(children: [
          Padding(
            padding: EdgeInsets.only(top: Dimensions.height30 / 1.5,
                right: Dimensions.width40 / 1.5),
            child: Align(
              alignment: Alignment.centerRight,
              child: GestureDetector(
                  onTap: _changeLanguage,
                  child: _lang == "KZ" ? SizedBox(width:Dimensions.width20*1.25,height: Dimensions.height30*1.25, child: Image.asset('assets/ru.png')) : Container(child: Image.asset('assets/kz.png'), width:Dimensions.width20*1.25,height: Dimensions.height30*1.25)),
            ),
          ),
          Padding(
              padding: EdgeInsets.only(left: Dimensions.width40, right: Dimensions.width40),
              child: SizedBox(
                height: Dimensions.height100 * 1.3,
                child: Image.asset('assets/logo.png'),
              )
          ),
          Padding(
              padding: EdgeInsets.only(top: Dimensions.height60/6, left: Dimensions.width40, right: Dimensions.width40),
              child: CustomLoginField(
                hintText: 'login'.tr,
                obscureText: false,
                controller: loginController,
                fontSize: Dimensions.fontSize20,
                backgroundColor: AppColors.loginField,
              )),
          Padding(
              padding: EdgeInsets.only(top: Dimensions.height30, left: Dimensions.width40, right: Dimensions.width40),
              child: LoginButton(
                  inButton: BigText(
                    fontWeight: FontWeight.bold,
                    overflow: TextOverflow.visible,
                    content: "log in".tr,
                    color: AppColors.niceWhite,
                  )
              )),
        ]),
      ),
    );
  }
  _changeLanguage() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    if (_lang == "KZ") {
      prefs.setString(AppValues.LANG, "RU");
      var locale = Locale(prefs.getString(AppValues.LANG)!);
      Get.updateLocale(locale);
      setState(() {
        _lang = prefs.getString(AppValues.LANG)!;
      });
    } else if (_lang == "RU") {
      prefs.setString(AppValues.LANG, "KZ");
      var locale = Locale(prefs.getString(AppValues.LANG)!);
      Get.updateLocale(locale);
      setState(() {
        _lang = prefs.getString(AppValues.LANG)!;
      });
    }
  }
}