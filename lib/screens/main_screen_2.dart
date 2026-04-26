import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:se_mobile/functions/generate_excel.dart';
import 'package:se_mobile/requests/employeedate_request.dart';
import 'package:se_mobile/requests/get_all_employees.dart';
import 'package:se_mobile/screens/start_screen.dart';
import 'package:se_mobile/utils/secure_storage_helper.dart';
import 'package:se_mobile/utils/shared_preferences_helper.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../functions/generate_csv.dart';
import '../requests/reportdate_request.dart';
import '../utils/colors.dart';
import '../utils/dimensions.dart';
import '../utils/variables.dart';
import '../widgets/custom_text.dart';
import '../widgets/icon_button_drawer.dart';

class MainPage2 extends StatefulWidget {
  final String fullName;
  final String job;

  const MainPage2({Key? key, required this.fullName, required this.job}) : super(key: key);

  @override
  State<MainPage2> createState() => _MainPage2State();
}


class _MainPage2State extends State<MainPage2> {

  static TextEditingController employeeController = TextEditingController();

  late String employeeId;
  late String employeeName;
  late DateTime startDate;
  late DateTime endDate;
  bool isStartDateInitialized = false;
  bool isEndDateInitialized = false;
  List<List<String>> reportsEntries = [["", "", "", ""]];
  List<List<List<String>>> reportsEntriesForMsg = [];
  List<String> employees = [];
  static String _lang = "";
  late SharedPreferences prefs;

  String searchText = '';
  List<String> allEmployees = [];
  List<String> filteredEmployees = [];

  @override
  void initState() {
    super.initState();
    initializeData();
    initializeSharedPreferences();
    employeeController.addListener(() {
      setState(() {
        searchText = employeeController.text;
        filteredEmployees = allEmployees
            .where((employee) =>
            employee.toLowerCase().contains(employeeController.text.toLowerCase()))
            .toList();
      });
    });
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

  Future<void> initializeData() async {
    employeeName = '';
    startDate = DateTime.utc(2023, 5, 1);
    endDate = DateTime.now();
    isStartDateInitialized = true;
    isEndDateInitialized = true;

    setState(() {

    });
  }


  Future<void> fetchReportData() async {
    if (prefs.containsKey('emp_sname') && prefs.getString('emp_sname')?.length != 1){
      reportsEntries = await getEmployeeDate(context, DateFormat('dd.MM.yyyy').format(startDate),
        DateFormat('dd.MM.yyyy').format(endDate),);
      reportsEntriesForMsg.add(reportsEntries);
    } else {
      reportsEntries = await getReportDateEntries(context, DateFormat('dd.MM.yyyy').format(startDate),
        DateFormat('dd.MM.yyyy').format(endDate),);
    }
    setState(() {

    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: BigText(content: "attendance report".tr, fontWeight: FontWeight.bold,),
        centerTitle: true,
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
                  generateExcelEmp(reportsEntriesForMsg, context);
                  break;
                case "Есепті Excel бағдарламасына жүктеңіз":
                  generateExcelEmp(reportsEntriesForMsg, context);
                  break;
                case "Отправить отчёт csv":
                  generateTableEmp(reportsEntriesForMsg, context);
                  break;
                case "CSV форматындағы ақырғы файлды көру":
                  generateTableEmp(reportsEntriesForMsg, context);
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
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextButton(
                onPressed: () async {
                  final directory = await getExternalStorageDirectories();
                  if (directory == null || directory.isEmpty) return;
                  try {
                    OpenFile.open("${directory[0].path}/saved_report.xlsx");
                  } catch (e) {
                    print(e);
                  }
                },
                child: SmallText(content: "see last Excel".tr,),
              ),
              TextButton(
                onPressed: () async {
                  final directory = await getExternalStorageDirectories();
                  if (directory == null || directory.isEmpty) return;
                  try {
                    OpenFile.open("${directory[0].path}/saved_report.csv");
                  } catch (e) {
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
                          locale: const Locale('ru'),
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
                        padding: EdgeInsets.all(16.0),
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
                          locale: const Locale('ru'),
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
              const SizedBox(height: 16.0,),
              const SizedBox(height: 8.0),
              BigText(content: "choose employee".tr, fontWeight: FontWeight.bold,),
              const SizedBox(height: 8.0),
              ElevatedButton(
                onPressed: () async {
                  await showDialog(
                    context: context,
                    builder: (BuildContext context) {
                      return AlertDialog(
                        title: TextField(
                          controller: employeeController,
                          onChanged: (value) {
                            setState(() {
                              searchText = value;
                              filteredEmployees = allEmployees
                                  .where((employee) =>
                                  employee.toLowerCase().contains(value.toLowerCase()))
                                  .toList();
                            });
                          },
                          decoration: InputDecoration(
                            labelText: 'search'.tr,
                          ),
                        ),
                        content: SingleChildScrollView(
                          child: SizedBox(
                            width: double.maxFinite,
                            height: Dimensions.height120 * 3,
                            child: FutureBuilder(
                              future: getAllEmployees(context),
                              builder: (BuildContext context, snapshot) {
                                if (snapshot.hasData) {
                                  allEmployees = snapshot.data!;
                                  List<String> displayedEmployees =
                                  searchText.isEmpty ? allEmployees : filteredEmployees;
                                  return ListView(
                                    shrinkWrap: true,
                                    children: displayedEmployees.map((employee) {
                                      return ListTile(
                                        title: Text(employee),
                                        onTap: () async {
                                          employeeName = employee;
                                          employees.add(employeeName);
                                          prefs.setStringList("emp_snames", employees);
                                          prefs.setString("emp_sname", employeeName);
                                          reportsEntries = await getEmployeeDate(context, DateFormat('dd.MM.yyyy').format(startDate),
                                            DateFormat('dd.MM.yyyy').format(endDate),);
                                          reportsEntriesForMsg.add(reportsEntries);
                                          setState(() {

                                          });
                                          Navigator.pop(context);
                                        },
                                      );
                                    }).toList(),
                                  );
                                } else if (snapshot.connectionState ==
                                    ConnectionState.waiting) {
                                  return Column(
                                    children: [
                                      Padding(
                                        padding: EdgeInsets.only(
                                            top: Dimensions.height30 / 2),
                                        child: const CircularProgressIndicator(),
                                      ),
                                    ],
                                  );
                                } else {
                                  return const Text("");
                                }
                              },
                            ),
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () {
                              Navigator.of(context).pop();
                            },
                            child: Text('cancel'.tr),
                          ),
                        ],
                      );
                    },
                  );
                },
                child: MediumText(
                  content: "search".tr,
                  fontWeight: FontWeight.bold,
                  maxLines: 1,
                ),
              ),
              const SizedBox(height: 16.0),
              ListView.builder(
                itemCount: employees.length,
                shrinkWrap: true,
                itemBuilder: (context, index) {
                  return Row(
                    children: [
                      Text(
                        employees[index] ?? '',
                        style: const TextStyle(fontSize: 16.0),
                      ),
                      IconButton(
                          onPressed: (){
                            setState(() {
                              employees.removeAt(index);
                              reportsEntriesForMsg.removeAt(index);
                              prefs.setStringList("emp_snames", employees);
                              List<String>? names = prefs.getStringList("emp_snames");
                              if (names!.length >= 1){
                                employeeName = names[names.length - 1];
                                prefs.setString("emp_sname", employeeName);
                              } else {
                                prefs.setString("emp_sname", "");
                              }
                            });
                          },
                          icon: const Icon(Icons.remove_circle_outline)
                      )
                    ],
                  );
                },
              ),
              const SizedBox(height: 16.0),
              /*ElevatedButton(
                onPressed: () {
                  employees = [];
                  reportsEntriesForMsg = [];
                  prefs.remove("emp_sname") ;
                  fetchReportData();
                },
                child: MediumText(content: "show report".tr, fontWeight: FontWeight.bold, maxLines: 1,),
              ),*/
              const SizedBox(height: 8.0),
              Text(
                "info".tr,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8.0),
              Text(
                'scroll to right'.tr,
                style: const TextStyle(fontSize: 12.0, color: Colors.grey),
              ),
              const SizedBox(height: 8.0),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: Dimensions.width120 * 4,
                  child: DataTable(
                    columns: const [
                      DataColumn(label: Text('Дата')),
                      DataColumn(label: Text('Время')),
                      DataColumn(label: Text('Событие')),
                      DataColumn(label: Text('Дверь')),
                    ],
                    rows: reportsEntries.map((entry) {
                      return DataRow(cells: [
                        DataCell(Text(entry[0])),
                        DataCell(Text(entry[1])),
                        DataCell(Text(entry[2])),
                        DataCell(Text(entry[3])),
                      ]);
                    }).toList(),
                  ),
                ),

              ),
              const SizedBox(height: 16.0),
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