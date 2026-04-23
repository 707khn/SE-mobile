import 'dart:io';

import 'package:filesystem_picker/filesystem_picker.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:se_mobile/functions/generate_excel.dart';
import 'package:se_mobile/requests/report_request.dart';
import 'package:se_mobile/screens/leave_screen.dart';
import 'package:se_mobile/requests/reportdate_request.dart';
import 'package:se_mobile/screens/payslip_screen.dart';
import 'package:se_mobile/screens/start_screen.dart';
import 'package:se_mobile/utils/secure_storage_helper.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../functions/generate_csv.dart';
import '../utils/colors.dart';
import '../utils/dimensions.dart';
import '../utils/variables.dart';
import '../variables.dart';
import '../widgets/custom_text.dart';
import '../widgets/icon_button_drawer.dart';


class MainPage1 extends StatefulWidget {
  final String fullName;
  final String job;

  const MainPage1({Key? key, required this.fullName, required this.job}) : super(key: key);

  @override
  State<MainPage1> createState() => _MainPage1State();
}

class _MainPage1State extends State<MainPage1> {
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
      backgroundColor: AppColors.niceWhite,
      appBar: AppBar(
        centerTitle: true,
        title: BigText(content: "attendance report".tr, fontWeight: FontWeight.bold,),
        actions: [
          PopupMenuButton(
            icon: const Icon(Icons.share),
            tooltip: 'Отправить отчёт',
            itemBuilder: (BuildContext context) {
              return {"send report exc".tr, "send report csv".tr}.map((String choice) {
                return PopupMenuItem<String>(
                  value: choice,
                  child: Text(choice),
                );
              }).toList();
            },
            onSelected: (String value) {
              switch (value) {
                case "Отправить отчёт Excel":
                  generateExcel(reportsEntries);
                  break;
                case "Есепті Excel бағдарламасына жүктеңіз":
                  generateExcel(reportsEntries);
                  break;
                case "Отправить отчёт csv":
                  generateTable(reportsEntries);
                  break;
                case "CSV форматындағы ақырғы файлды көру":
                  generateTable(reportsEntries);
                  break;
              }
            },

          ),
        ],
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
                            mainAxisAlignment: MainAxisAlignment.end, // Align to the bottom
                            crossAxisAlignment: CrossAxisAlignment.start, // Align to the left
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
                                              : SizedBox(
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
                      ListTile(
                        leading: const Icon(Icons.receipt_long, color: AppColors.mainColor),
                        title: BigText(content: 'payslip'.tr),
                        onTap: () {
                          Navigator.pop(context);
                          Get.to(() => const PayslipPage());
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.calendar_today, color: AppColors.mainColor),
                        title: BigText(content: 'leave_sick_days'.tr),
                        onTap: () {
                          Navigator.pop(context);
                          Get.to(() => const LeavePage());
                        },
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
      body: const MainMenu1(),
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
    reportsEntries = [["", "", "", ""]];
    Get.offAll(() => const StartPage());
  }
}

class MainMenu1 extends StatefulWidget {
  const MainMenu1({Key? key}) : super(key: key);



  @override
  State<MainMenu1> createState() => _MainMenu1State();
}

class _MainMenu1State extends State<MainMenu1> {
  late String employeeId;
  late String employeeName;
  late DateTime startDate;
  late DateTime endDate;
  bool isStartDateInitialized = false;
  bool isEndDateInitialized = false;


  @override
  void initState() {
    super.initState();
    initializeData();
  }

  Future<void> initializeData() async {
    employeeName = '';
    startDate = DateTime.now();
    endDate = DateTime.now();
    isStartDateInitialized = true;
    isEndDateInitialized = true;
    reportsEntries = await getReportEntries(context);

    setState(() {
      // Update the state variables after initializing the reportsEntries
    });
  }

  List<bool> openableData = List.filled(200, false, growable: false);
  int opened = 0;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Container(
        padding: EdgeInsets.only(top: Dimensions.height30 / 2, left: Dimensions.width20, right: Dimensions.width20),
        child: Column(
          children: [
            const SizedBox(height: 4.0),
            TextButton(
              onPressed: () async {
                final directory = await getExternalStorageDirectories();
                try {
                  OpenFile.open("${directory![0].path}/saved_report.xlsx");
                } catch(e){
                  print(e);
                }
                /*String? path = await FilesystemPicker.open(
                  title: 'Open file',
                  context: context,
                  rootDirectory: directory![0],
                  fsType: FilesystemType.file,
                  fileTileSelectMode: FileTileSelectMode.wholeTile,
                );*/
              },
              child: SmallText(content: "see last Excel".tr,),
            ),
            const SizedBox(height: 4.0),
            TextButton(
              onPressed: () async {
                final directory = await getExternalStorageDirectories();
                try {
                  OpenFile.open("${directory![0].path}/saved_report.csv");
                } catch(e){
                  print(e);
                }
              },
              child: SmallText(content: "see last CSV".tr,),
            ),
            const SizedBox(height: 4.0),
            BigText(content: "choose period".tr, fontWeight: FontWeight.bold,),
            const SizedBox(height: 8.0),
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () async {
                      final selectedDate = await showDatePicker(
                        context: context,
                        initialDate: isStartDateInitialized ? startDate : DateTime.now(),
                        locale: const Locale('ru', ''),
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (selectedDate != null) {
                        setState(() {
                          startDate = selectedDate;
                          isStartDateInitialized = true;
                        });
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.all(16.0),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey),
                      ),
                      child: Text(
                        isStartDateInitialized
                            ? '${startDate.day}.${startDate.month}.${startDate.year}'
                            : 'Начальная дата',
                        style: const TextStyle(fontSize: 16.0),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8.0),
                Expanded(
                  child: InkWell(
                    onTap: () async {
                      final selectedDate = await showDatePicker(
                        context: context,
                        initialDate: isEndDateInitialized ? endDate : DateTime.now(),
                        locale: const Locale('ru', ''),
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (selectedDate != null) {
                        setState(() {
                          endDate = selectedDate;
                          isEndDateInitialized = true;
                        });
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.all(16.0),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey),
                      ),
                      child: Text(
                        isEndDateInitialized
                            ? '${endDate.day}.${endDate.month}.${endDate.year}'
                            : 'Конечная дата',
                        style: const TextStyle(fontSize: 16.0),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: Dimensions.height30 / 5),
            TextButton(
                onPressed: () async{

                  reportsEntries = await getReportDateEntries(context, DateFormat('dd.MM.yyyy').format(startDate), // Format startDate as "dd.MM.yyyy"
                    DateFormat('dd.MM.yyyy').format(endDate),);
                  setState(() {

                  });
                },
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.onPrimary,
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  elevation: 3,
                  minimumSize: Size(Dimensions.width120, Dimensions.height30),
                ),
                child: MediumText(content: "show report".tr, fontWeight: FontWeight.bold,maxLines: 1)
            ),
            SizedBox(height: Dimensions.height30 / 3,),
            Text(
              'scroll to right'.tr,
              style: const TextStyle(fontSize: 12.0, color: Colors.grey),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: Dimensions.width120 * 4, // Adjust the width as needed// Adjust the height as needed
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('Дата')),
                    DataColumn(label: Text('Время')),
                    DataColumn(label: Text('Событие')),
                    DataColumn(label: Text('Дверь')),
                  ],
                  rows: reportsEntries.map((entry) {
                    return DataRow(cells: [
                      DataCell(Text(entry[0])), // Вывод даты
                      DataCell(Text(entry[1])), // Вывод времени
                      DataCell(Text(entry[2])),
                      DataCell(Text(entry[3])),
                    ]);
                  }).toList(),
                ),
              ),

            ),
            SizedBox(
              height: Dimensions.height30,
            ),
            /*TextButton(
              onPressed: (){
                generateExcel(reportsEntries);
              },
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
                backgroundColor: Theme.of(context).colorScheme.primary,
                elevation: 5,
                minimumSize: Size(Dimensions.screenWidth, Dimensions.height30 * 1.5),
              ),
              child: BigText(content: "send report exc".tr, fontWeight: FontWeight.bold,),
            ),
            SizedBox(
              height: Dimensions.height30 / 2,
            ),
            TextButton(
              onPressed: (){
                generateTable(reportsEntries);
              },
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
                backgroundColor: Theme.of(context).colorScheme.primary,
                elevation: 5,
                minimumSize: Size(Dimensions.screenWidth, Dimensions.height30 * 1.5),
              ),
              child: BigText(content: "send report csv".tr, fontWeight: FontWeight.bold,),
            ),
            SizedBox(
              height: Dimensions.height30,
            ),*/
          ],
        ),
      ),
    );
  }

}