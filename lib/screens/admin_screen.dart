import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:se_mobile/screens/main_screen_1.dart';
import 'package:se_mobile/utils/dimensions.dart';
import 'package:se_mobile/widgets/custom_text.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../utils/colors.dart';
import '../utils/secure_storage_helper.dart';
import '../utils/variables.dart';
import '../widgets/icon_button_drawer.dart';
import 'main_screen_2.dart';
import 'payslip_screen.dart';
import 'start_screen.dart';

class AdminPage extends StatefulWidget {
  const AdminPage({super.key, required this.fullName, required this.job});

  final String fullName;
  final String job;

  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage> {

  static String _lang = "";
  late SharedPreferences prefs;

  @override
  void initState() {
    super.initState();
    initializeSharedPreferences();
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
    return Scaffold(
      appBar: AppBar(
        title: BigText(content: "attendance report".tr, fontWeight: FontWeight.bold,),
      ),
      drawer: Theme(
        data: Theme.of(context).copyWith(
          canvasColor: Theme.of(context).scaffoldBackgroundColor,
        ),
        child: SizedBox(
          width: Dimensions.width120 * 2.5,
          child: Drawer(
            child: Column(
              children: <Widget>[
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.zero,
                    children: <Widget>[
                      SizedBox(
                        height: Dimensions.height120 * 2,
                        child: DrawerHeader(
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.secondary,
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Wrap(
                                children: [
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      BigText(
                                        content: widget.fullName,
                                        color: AppColors.niceWhite,
                                        fontWeight: FontWeight.bold,
                                      ),
                                      MediumText(
                                        content: widget.job,
                                        color: AppColors.niceWhite,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),

                                  Row(
                                    children: [
                                      Padding(
                                        padding: EdgeInsets.only(right: Dimensions.width20 / 1.5),
                                        child: GestureDetector(
                                          onTap: _changeLanguage,
                                          child: _lang == "KZ"
                                              ? SizedBox(
                                            width: Dimensions.width20 * 1.25,
                                            height: Dimensions.height30 * 1.25,
                                            child: Image.asset('assets/ru.png'),
                                          )
                                              : Container(
                                            width: Dimensions.width20 * 1.25,
                                            height: Dimensions.height30 * 1.25,
                                            child: Image.asset('assets/kz.png'),
                                          ),
                                        ),
                                      ),
                                      GestureDetector(
                                        onTap: _exit,
                                        child: Image.asset(
                                          'assets/door.png',
                                          color: AppColors.niceWhite,
                                          height: Dimensions.height30 / 1.1,
                                        ),
                                      )
                                    ],
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),


                Container(
                  height: Dimensions.height30 / 15,
                  width: Dimensions.width120 * 2,
                  color: Colors.black26,
                ),
                Container(
                    padding: EdgeInsets.only(
                        bottom: Dimensions.height30,
                        top: Dimensions.height30 / 2),
                    height: Dimensions.height60 * 1.5,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        IconButtonDrawer(
                          icon: Image.asset('assets/youtube.png'),
                          function: () async {
                            const url = 'https://www.youtube.com/@semeyengineering4367';
                            await launch(url);
                          },
                        ),
                        IconButtonDrawer(
                          icon: Image.asset('assets/instagram.png'),
                          function: () async {
                            const url = 'https://www.instagram.com/jscsemeyengineering/';
                            await launch(url);
                          },
                        ),
                        IconButtonDrawer(
                          icon: Image.asset('assets/facebook.png'),
                          function: () async {
                            const url = 'https://www.facebook.com/semeybtrz/';
                            await launch(url);
                          },),
                        IconButtonDrawer(
                          icon: Image.asset('assets/web.png'),
                          function: () async {
                            const url = 'https://se-btrz.com/';
                            await launch(url);
                          },
                        ),
                      ],
                    )),
              ],
            ),
          ),
        ),
      ),
      body: SingleChildScrollView(
        child: Center(
          child: Column(
            children: [
              SizedBox(
                height: Dimensions.height60 * 1.25,
              ),
              Icon(Icons.person, size: Dimensions.height120,),
              Container(
                padding: EdgeInsets.only(left: Dimensions.width20, right: Dimensions.width20),
                decoration: BoxDecoration(
                  borderRadius:  BorderRadius.all(Radius.circular(Dimensions.radius50))
                ),
                child: ElevatedButton(
                    onPressed: (){
                      Get.to(() => MainPage1(fullName: widget.fullName, job: widget.job,));
                    },
                    child: Container(
                        padding: EdgeInsets.only(top: Dimensions.height30 /2, bottom: Dimensions.height30 / 2),
                        child: BigText(content: "self report".tr, fontWeight: FontWeight.bold, overflow: TextOverflow.visible,)
                    )
                ),
              ),
              SizedBox(
                height: Dimensions.height60,
              ),
              Icon(Icons.groups, size: Dimensions.height120,),
              Container(
                padding: EdgeInsets.only(left: Dimensions.width20, right: Dimensions.width20),
                decoration: BoxDecoration(
                    borderRadius:  BorderRadius.all(Radius.circular(Dimensions.radius50))
                ),
                child: ElevatedButton(
                    onPressed: (){
                      Get.to(() => MainPage2(fullName: widget.fullName, job: widget.job,));
                    },
                    child: Container(
                        padding: EdgeInsets.only(top: Dimensions.height30 /2, bottom: Dimensions.height30 / 2),
                        child: BigText(content: "employee report".tr, fontWeight: FontWeight.bold, overflow: TextOverflow.visible,)
                    )
                ),
              ),
              SizedBox(
                height: Dimensions.height60,
              ),
              Icon(Icons.receipt_long, size: Dimensions.height120,),
              Container(
                padding: EdgeInsets.only(left: Dimensions.width20, right: Dimensions.width20),
                decoration: BoxDecoration(
                    borderRadius:  BorderRadius.all(Radius.circular(Dimensions.radius50))
                ),
                child: ElevatedButton(
                    onPressed: (){
                      Get.to(() => const PayslipPage());
                    },
                    child: Container(
                        padding: EdgeInsets.only(top: Dimensions.height30 /2, bottom: Dimensions.height30 / 2),
                        child: BigText(content: "payslip".tr, fontWeight: FontWeight.bold, overflow: TextOverflow.visible,)
                    )
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

  _exit() async{
    await SecureStorageHelper.instance.clearCredentials();
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    Get.offAll(() => const StartPage());
  }
}
