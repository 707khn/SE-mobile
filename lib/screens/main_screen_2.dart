import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:se_mobile/functions/generate_excel.dart';
import 'package:se_mobile/requests/employeedate_request.dart';
import 'package:se_mobile/requests/get_all_employees.dart';
import 'package:se_mobile/screens/start_screen.dart';
import 'package:se_mobile/utils/logout_helper.dart';
import 'package:se_mobile/utils/secure_storage_helper.dart';
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

  late DateTime startDate;
  late DateTime endDate;
  bool _loadingReport = false;
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
    startDate = DateTime.utc(2023, 5, 1);
    endDate = DateTime.now();
    _initPrefs();
    employeeController.addListener(() {
      setState(() {
        searchText = employeeController.text;
        filteredEmployees = allEmployees
            .where((e) => e.toLowerCase().contains(employeeController.text.toLowerCase()))
            .toList();
      });
    });
  }

  Future<void> _initPrefs() async {
    prefs = await SharedPreferences.getInstance();
    if (prefs.getString(AppValues.LANG) == null) {
      prefs.setString(AppValues.LANG, "KZ");
    }
    setState(() {
      _lang = prefs.getString(AppValues.LANG)!;
    });
  }

  bool get _hasData =>
      reportsEntries.isNotEmpty &&
      !(reportsEntries.length == 1 && reportsEntries[0][0].isEmpty);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: BigText(content: "attendance report".tr, fontWeight: FontWeight.bold),
        centerTitle: true,
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.share),
            tooltip: 'send_report_tooltip'.tr,
            itemBuilder: (_) => [
              PopupMenuItem(value: 'send report exc', child: Text('send report exc'.tr)),
              PopupMenuItem(value: 'send report csv', child: Text('send report csv'.tr)),
            ],
            onSelected: (value) {
              if (value == 'send report exc') {
                generateExcelEmp(reportsEntriesForMsg, context);
              } else if (value == 'send report csv') {
                generateTableEmp(reportsEntriesForMsg, context);
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
                    top: Dimensions.height30 / 2,
                  ),
                  height: Dimensions.height60 * 1.5,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButtonDrawer(
                        icon: Image.asset('assets/youtube.png'),
                        function: () async {
                          await launchUrl(Uri.parse('https://www.youtube.com/@semeyengineering4367'), mode: LaunchMode.externalApplication);
                        },
                      ),
                      IconButtonDrawer(
                        icon: Image.asset('assets/instagram.png'),
                        function: () async {
                          await launchUrl(Uri.parse('https://www.instagram.com/jscsemeyengineering/'), mode: LaunchMode.externalApplication);
                        },
                      ),
                      IconButtonDrawer(
                        icon: Image.asset('assets/facebook.png'),
                        function: () async {
                          await launchUrl(Uri.parse('https://www.facebook.com/semeybtrz/'), mode: LaunchMode.externalApplication);
                        },
                      ),
                      IconButtonDrawer(
                        icon: Image.asset('assets/web.png'),
                        function: () async {
                          await launchUrl(Uri.parse('https://se-btrz.com/'), mode: LaunchMode.externalApplication);
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton.icon(
                    onPressed: () async {
                      final directory = await getExternalStorageDirectories();
                      if (directory == null || directory.isEmpty) return;
                      try {
                        OpenFile.open("${directory[0].path}/saved_report.xlsx");
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('url_error'.tr)),
                          );
                        }
                      }
                    },
                    icon: const Icon(Icons.table_chart_outlined, size: 16),
                    label: SmallText(content: "see last Excel".tr),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: () async {
                      final directory = await getExternalStorageDirectories();
                      if (directory == null || directory.isEmpty) return;
                      try {
                        OpenFile.open("${directory[0].path}/saved_report.csv");
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('url_error'.tr)),
                          );
                        }
                      }
                    },
                    icon: const Icon(Icons.description_outlined, size: 16),
                    label: SmallText(content: "see last CSV".tr),
                  ),
                ],
              ),
              const SizedBox(height: 4.0),
              BigText(content: "choose period".tr, fontWeight: FontWeight.bold),
              const SizedBox(height: 8.0),
              Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () async {
                        final selected = await showDatePicker(
                          context: context,
                          initialDate: startDate,
                          locale: const Locale('ru'),
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2100),
                        );
                        if (selected != null) setState(() => startDate = selected);
                      },
                      child: Container(
                        padding: const EdgeInsets.all(16.0),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.calendar_today, size: 16, color: Colors.grey),
                            const SizedBox(width: 6),
                            Text(
                              '${startDate.day.toString().padLeft(2, '0')}.${startDate.month.toString().padLeft(2, '0')}.${startDate.year}',
                              style: const TextStyle(fontSize: 15.0),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text('—', style: TextStyle(color: Colors.grey.shade600)),
                  ),
                  Expanded(
                    child: InkWell(
                      onTap: () async {
                        final selected = await showDatePicker(
                          context: context,
                          initialDate: endDate,
                          locale: const Locale('ru'),
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2100),
                        );
                        if (selected != null) setState(() => endDate = selected);
                      },
                      child: Container(
                        padding: const EdgeInsets.all(16.0),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.calendar_today, size: 16, color: Colors.grey),
                            const SizedBox(width: 6),
                            Text(
                              '${endDate.day.toString().padLeft(2, '0')}.${endDate.month.toString().padLeft(2, '0')}.${endDate.year}',
                              style: const TextStyle(fontSize: 15.0),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16.0),
              BigText(content: "choose employee".tr, fontWeight: FontWeight.bold),
              const SizedBox(height: 8.0),
              ElevatedButton.icon(
                icon: const Icon(Icons.person_search),
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
                                  .where((e) => e.toLowerCase().contains(value.toLowerCase()))
                                  .toList();
                            });
                          },
                          decoration: InputDecoration(
                            labelText: 'search'.tr,
                            prefixIcon: const Icon(Icons.search),
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
                                  final displayed = searchText.isEmpty
                                      ? allEmployees
                                      : filteredEmployees;
                                  if (displayed.isEmpty) {
                                    return Center(
                                      child: Text(
                                        'no_records'.tr,
                                        style: const TextStyle(color: Colors.grey),
                                      ),
                                    );
                                  }
                                  return ListView(
                                    shrinkWrap: true,
                                    children: displayed.map((employee) {
                                      return ListTile(
                                        title: Text(employee),
                                        onTap: () async {
                                          employees.add(employee);
                                          prefs.setStringList("emp_snames", employees);
                                          prefs.setString("emp_sname", employee);
                                          setState(() => _loadingReport = true);
                                          final data = await getEmployeeDate(
                                            context,
                                            DateFormat('dd.MM.yyyy').format(startDate),
                                            DateFormat('dd.MM.yyyy').format(endDate),
                                          );
                                          reportsEntries = data;
                                          reportsEntriesForMsg.add(data);
                                          if (mounted) setState(() => _loadingReport = false);
                                          Navigator.pop(context);
                                        },
                                      );
                                    }).toList(),
                                  );
                                } else if (snapshot.connectionState == ConnectionState.waiting) {
                                  return const Center(child: CircularProgressIndicator());
                                } else {
                                  return Center(child: Text('no_records'.tr, style: const TextStyle(color: Colors.grey)));
                                }
                              },
                            ),
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: Text('cancel'.tr),
                          ),
                        ],
                      );
                    },
                  );
                },
                label: MediumText(content: "search".tr, fontWeight: FontWeight.bold, maxLines: 1),
              ),
              const SizedBox(height: 8.0),
              if (employees.isNotEmpty) ...[
                ListView.builder(
                  itemCount: employees.length,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemBuilder: (context, index) {
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.person_outline, color: AppColors.mainColor),
                        title: Text(employees[index]),
                        trailing: IconButton(
                          onPressed: () {
                            setState(() {
                              employees.removeAt(index);
                              reportsEntriesForMsg.removeAt(index);
                              prefs.setStringList("emp_snames", employees);
                              if (employees.isNotEmpty) {
                                prefs.setString("emp_sname", employees.last);
                              } else {
                                prefs.setString("emp_sname", "");
                              }
                            });
                          },
                          icon: const Icon(Icons.remove_circle_outline, color: AppColors.niceRed),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 8),
              ],
              const SizedBox(height: 8.0),
              Text(
                "info".tr,
                style: const TextStyle(fontSize: 14, color: Colors.black54),
              ),
              const SizedBox(height: 8.0),
              if (_loadingReport)
                const Center(child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ))
              else if (_hasData) ...[
                Text(
                  'scroll to right'.tr,
                  style: const TextStyle(fontSize: 12.0, color: Colors.grey),
                ),
                const SizedBox(height: 4),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: Dimensions.width120 * 4,
                    child: DataTable(
                      columns: [
                        DataColumn(label: Text('col_date'.tr)),
                        DataColumn(label: Text('col_time'.tr)),
                        DataColumn(label: Text('col_event'.tr)),
                        DataColumn(label: Text('col_door'.tr)),
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
              ] else ...[
                const SizedBox(height: 24),
                Icon(Icons.inbox_outlined, size: 56, color: Colors.grey.shade400),
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    'no_data'.tr,
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 15),
                  ),
                ),
              ],
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
      Get.updateLocale(Locale(prefs.getString(AppValues.LANG)!));
      setState(() => _lang = prefs.getString(AppValues.LANG)!);
    } else if (_lang == "RU") {
      prefs.setString(AppValues.LANG, "KZ");
      Get.updateLocale(Locale(prefs.getString(AppValues.LANG)!));
      setState(() => _lang = prefs.getString(AppValues.LANG)!);
    }
  }

  _exit() => confirmAndLogout(context);
}
