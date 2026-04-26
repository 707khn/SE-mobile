import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:se_mobile/functions/generate_excel.dart';
import 'package:se_mobile/requests/employeedate_request.dart';
import 'package:se_mobile/requests/get_all_employees.dart';
import 'package:se_mobile/screens/leave_screen.dart';
import 'package:se_mobile/screens/payslip_screen.dart';
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
  String? _login;
  late SharedPreferences prefs;

  String searchText = '';
  List<String> allEmployees = [];
  List<String> filteredEmployees = [];
  bool _dateError = false;
  List<String>? _employeesCache;
  bool _employeesCacheLoading = false;
  String _filterText = '';
  final _filterController = TextEditingController();

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
    final savedEmployees = prefs.getStringList("emp_snames");
    final login = await SecureStorageHelper.instance.getLogin();
    setState(() {
      _lang = prefs.getString(AppValues.LANG)!;
      _login = login;
      if (savedEmployees != null && savedEmployees.isNotEmpty) {
        employees = savedEmployees;
      }
    });
  }

  bool get _hasData =>
      reportsEntries.isNotEmpty &&
      !(reportsEntries.length == 1 &&
          (reportsEntries[0][0].isEmpty || reportsEntries[0][0] == 'no'));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            BigText(content: "attendance report".tr, fontWeight: FontWeight.bold),
            if (_hasData)
              Text(
                '${startDate.day.toString().padLeft(2, '0')}.${startDate.month.toString().padLeft(2, '0')}.${startDate.year}'
                ' — '
                '${endDate.day.toString().padLeft(2, '0')}.${endDate.month.toString().padLeft(2, '0')}.${endDate.year}',
                style: const TextStyle(fontSize: 11, color: Colors.white70),
              ),
          ],
        ),
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
                                  GestureDetector(
                                    onLongPress: () {
                                      Clipboard.setData(ClipboardData(text: widget.fullName));
                                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                        content: Text('copied'.tr),
                                        duration: const Duration(seconds: 1),
                                        behavior: SnackBarBehavior.floating,
                                      ));
                                    },
                                    child: Column(
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
                                        if (_login != null && _login!.isNotEmpty) ...[
                                          const SizedBox(height: 2),
                                          GestureDetector(
                                            onTap: () {
                                              Clipboard.setData(ClipboardData(text: _login!));
                                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                                content: Text('copied'.tr),
                                                duration: const Duration(seconds: 1),
                                                behavior: SnackBarBehavior.floating,
                                              ));
                                            },
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const Icon(Icons.badge_outlined, size: 12, color: Colors.white54),
                                                const SizedBox(width: 4),
                                                Text(
                                                  _login!,
                                                  style: const TextStyle(
                                                    color: Colors.white54,
                                                    fontSize: 12,
                                                    letterSpacing: 1,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
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
                        subtitle: Text('payslip_subtitle'.tr, style: const TextStyle(fontSize: 11)),
                        onTap: () {
                          Navigator.pop(context);
                          Get.to(() => const PayslipPage());
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.beach_access, color: AppColors.mainColor),
                        title: BigText(content: 'leave_sick_days'.tr),
                        subtitle: Text('leave_subtitle'.tr, style: const TextStyle(fontSize: 11)),
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
                        if (selected != null) {
                          setState(() {
                            startDate = selected;
                            _dateError = false;
                          });
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.all(16.0),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: _dateError ? Colors.red.shade700 : Colors.grey,
                            width: _dateError ? 1.5 : 1.0,
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.calendar_today, size: 16,
                                color: _dateError ? Colors.red.shade700 : Colors.grey),
                            const SizedBox(width: 6),
                            Text(
                              '${startDate.day.toString().padLeft(2, '0')}.${startDate.month.toString().padLeft(2, '0')}.${startDate.year}',
                              style: TextStyle(
                                fontSize: 15.0,
                                color: _dateError ? Colors.red.shade700 : null,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Builder(builder: (context) {
                    final diff = endDate.difference(startDate).inDays + 1;
                    final isInvalid = diff <= 0;
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('—', style: TextStyle(color: isInvalid ? Colors.red.shade700 : Colors.grey.shade600)),
                          Text(
                            isInvalid ? '!' : '$diff ${'days_short'.tr}',
                            style: TextStyle(
                              fontSize: 10,
                              color: isInvalid ? Colors.red.shade700 : Colors.grey.shade500,
                              fontWeight: isInvalid ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
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
                        if (selected != null) {
                          setState(() {
                            endDate = selected;
                            _dateError = false;
                          });
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.all(16.0),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: _dateError ? Colors.red.shade700 : Colors.grey,
                            width: _dateError ? 1.5 : 1.0,
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.calendar_today, size: 16,
                                color: _dateError ? Colors.red.shade700 : Colors.grey),
                            const SizedBox(width: 6),
                            Text(
                              '${endDate.day.toString().padLeft(2, '0')}.${endDate.month.toString().padLeft(2, '0')}.${endDate.year}',
                              style: TextStyle(
                                fontSize: 15.0,
                                color: _dateError ? Colors.red.shade700 : null,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _buildPresetChip('today'.tr, () {
                      final now = DateTime.now();
                      setState(() { startDate = now; endDate = now; _dateError = false; });
                    }),
                    const SizedBox(width: 6),
                    _buildPresetChip('this_week'.tr, () {
                      final now = DateTime.now();
                      final monday = now.subtract(Duration(days: now.weekday - 1));
                      setState(() { startDate = DateTime(monday.year, monday.month, monday.day); endDate = now; _dateError = false; });
                    }),
                    const SizedBox(width: 6),
                    _buildPresetChip('last_7_days'.tr, () {
                      final now = DateTime.now();
                      setState(() { startDate = now.subtract(const Duration(days: 6)); endDate = now; _dateError = false; });
                    }),
                    const SizedBox(width: 6),
                    _buildPresetChip('this_month'.tr, () {
                      final now = DateTime.now();
                      setState(() { startDate = DateTime(now.year, now.month, 1); endDate = now; _dateError = false; });
                    }),
                    const SizedBox(width: 6),
                    _buildPresetChip('last_month'.tr, () {
                      final now = DateTime.now();
                      final first = DateTime(now.year, now.month - 1, 1);
                      final last = DateTime(now.year, now.month, 0);
                      setState(() { startDate = first; endDate = last; _dateError = false; });
                    }),
                  ],
                ),
              ),
              const SizedBox(height: 12.0),
              Row(
                children: [
                  BigText(content: "choose employee".tr, fontWeight: FontWeight.bold),
                  if (employees.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.mainColor.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '${employees.length}',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: AppColors.mainColor,
                        ),
                      ),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () {
                        setState(() {
                          employees.clear();
                          reportsEntriesForMsg.clear();
                          reportsEntries = [["", "", "", ""]];
                        });
                        prefs.setStringList("emp_snames", []);
                        prefs.setString("emp_sname", "");
                      },
                      icon: const Icon(Icons.clear_all, size: 16),
                      label: Text('clear_all'.tr, style: const TextStyle(fontSize: 12)),
                      style: TextButton.styleFrom(foregroundColor: Colors.red.shade700),
                    ),
                  ],
                ],
              ),
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
                          autofocus: true,
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
                            suffixIcon: employeeController.text.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(Icons.clear),
                                    onPressed: () {
                                      employeeController.clear();
                                      setState(() {
                                        searchText = '';
                                        filteredEmployees = allEmployees;
                                      });
                                    },
                                  )
                                : null,
                          ),
                        ),
                        content: SingleChildScrollView(
                          child: SizedBox(
                            width: double.maxFinite,
                            height: Dimensions.height120 * 3,
                            child: FutureBuilder(
                              future: _getEmployeesCached(),
                              builder: (BuildContext context, snapshot) {
                                if (snapshot.hasData) {
                                  final raw = snapshot.data!;
                                  allEmployees = ([...raw]
                                    ..removeWhere((e) => e == 'no' || e.isEmpty)
                                    ..sort((a, b) => a.compareTo(b)));
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
                                          if (startDate.isAfter(endDate)) {
                                            final tmp = startDate;
                                            startDate = endDate;
                                            endDate = tmp;
                                          }
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
                                          if (mounted) {
                                            setState(() {
                                              _loadingReport = false;
                                              searchText = '';
                                              filteredEmployees = [];
                                              _filterText = '';
                                            });
                                            _filterController.clear();
                                          }
                                          employeeController.clear();
                                          Navigator.pop(context);
                                        },
                                      );
                                    }).toList(),
                                  );
                                } else if (snapshot.connectionState == ConnectionState.waiting) {
                                  return const Center(child: CircularProgressIndicator());
                                } else if (snapshot.hasError) {
                                  return Center(child: Text('load_error'.tr, style: const TextStyle(color: Colors.grey)));
                                } else {
                                  return Center(child: Text('load_error'.tr, style: const TextStyle(color: Colors.grey)));
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
                    return Dismissible(
                      key: Key('emp_${employees[index]}_$index'),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 16),
                        decoration: BoxDecoration(
                          color: AppColors.niceRed,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.delete_outline, color: Colors.white),
                      ),
                      onDismissed: (_) {
                        final removedName = employees[index];
                        final removedData = index < reportsEntriesForMsg.length
                            ? reportsEntriesForMsg[index]
                            : null;
                        setState(() {
                          employees.removeAt(index);
                          if (index < reportsEntriesForMsg.length) {
                            reportsEntriesForMsg.removeAt(index);
                          }
                          prefs.setStringList("emp_snames", employees);
                          if (employees.isNotEmpty) {
                            prefs.setString("emp_sname", employees.last);
                            if (reportsEntriesForMsg.isNotEmpty) {
                              reportsEntries = reportsEntriesForMsg.last;
                            }
                          } else {
                            prefs.setString("emp_sname", "");
                            reportsEntries = [["", "", "", ""]];
                          }
                        });
                        ScaffoldMessenger.of(context).clearSnackBars();
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(removedName),
                            duration: const Duration(seconds: 3),
                            behavior: SnackBarBehavior.floating,
                            action: SnackBarAction(
                              label: 'undo'.tr,
                              onPressed: () {
                                setState(() {
                                  employees.insert(index, removedName);
                                  if (removedData != null) {
                                    reportsEntriesForMsg.insert(index, removedData);
                                  }
                                  prefs.setStringList("emp_snames", employees);
                                  prefs.setString("emp_sname", employees.last);
                                  if (reportsEntriesForMsg.isNotEmpty) {
                                    reportsEntries = reportsEntriesForMsg.last;
                                  }
                                });
                              },
                            ),
                          ),
                        );
                      },
                      child: Card(
                        child: ListTile(
                          leading: const Icon(Icons.person_outline, color: AppColors.mainColor),
                          title: Text(employees[index]),
                          trailing: const Icon(Icons.swipe_left, size: 16, color: Colors.grey),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 8),
              ],
              const SizedBox(height: 8.0),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () {
                  showDialog(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: Row(
                        children: [
                          const Icon(Icons.info_outline, color: AppColors.mainColor),
                          const SizedBox(width: 8),
                          Text('info_title'.tr),
                        ],
                      ),
                      content: Text("info".tr),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: Text('cancel'.tr),
                        ),
                      ],
                    ),
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline, size: 16, color: Colors.grey),
                      const SizedBox(width: 6),
                      Text(
                        'info_hint'.tr,
                        style: const TextStyle(fontSize: 13, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8.0),
              if (_loadingReport)
                const Center(child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ))
              else if (_hasData) ...[
                if (employees.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppColors.mainColor.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.mainColor.withOpacity(0.2)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.person_outline, size: 16, color: AppColors.mainColor),
                        const SizedBox(width: 6),
                        Text(
                          '${'viewing_employee'.tr} ${employees.last}',
                          style: const TextStyle(
                            fontSize: 13,
                            color: AppColors.mainColor,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                TextField(
                  controller: _filterController,
                  onChanged: (v) => setState(() => _filterText = v),
                  decoration: InputDecoration(
                    hintText: 'search'.tr,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    suffixIcon: _filterText.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _filterController.clear();
                              setState(() => _filterText = '');
                            },
                          )
                        : null,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 6),
                Builder(builder: (context) {
                  final filtered = _filterText.isEmpty
                      ? reportsEntries
                      : reportsEntries
                          .where((e) => e.any((cell) =>
                              cell.toLowerCase().contains(_filterText.toLowerCase())))
                          .toList();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'scroll to right'.tr,
                      style: const TextStyle(fontSize: 12.0, color: Colors.grey),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _filterText.isEmpty
                              ? '${reportsEntries.length} ${'records_count'.tr}'
                              : '${filtered.length}/${reportsEntries.length} ${'records_count'.tr}',
                          style: TextStyle(fontSize: 12.0, color: Colors.grey.shade600),
                        ),
                        const SizedBox(width: 4),
                        InkWell(
                          borderRadius: BorderRadius.circular(4),
                          onTap: () {
                            final lines = filtered.map((e) =>
                                '${_formatDate(e[0])}\t${e[1]}\t${e[2]}\t${e[3]}').join('\n');
                            Clipboard.setData(ClipboardData(text: lines));
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text('copied'.tr),
                              duration: const Duration(seconds: 1),
                              behavior: SnackBarBehavior.floating,
                            ));
                          },
                          child: const Padding(
                            padding: EdgeInsets.all(2),
                            child: Icon(Icons.copy_outlined, size: 14, color: Colors.grey),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                _buildEventSummary(filtered),
                const SizedBox(height: 4),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: Dimensions.width120 * 4,
                    child: DataTable(
                      headingTextStyle: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: AppColors.mainColor,
                      fontSize: 13,
                    ),
                    columns: [
                        DataColumn(label: Text('col_date'.tr)),
                        DataColumn(label: Text('col_time'.tr)),
                        DataColumn(label: Text('col_event'.tr)),
                        DataColumn(label: Text('col_door'.tr)),
                      ],
                      rows: filtered.asMap().entries.map((e) {
                        final idx = e.key;
                        final entry = e.value;
                        final isToday = _isToday(entry[0]);
                        return DataRow(
                          color: WidgetStateProperty.all(
                            isToday
                                ? AppColors.mainColor.withOpacity(0.08)
                                : (idx.isEven ? Colors.transparent : Colors.grey.shade50),
                          ),
                          cells: [
                            DataCell(
                              Text(
                                _formatDate(entry[0]),
                                style: isToday
                                    ? const TextStyle(
                                        color: AppColors.mainColor,
                                        fontWeight: FontWeight.bold,
                                      )
                                    : null,
                              ),
                            ),
                            DataCell(Text(entry[1])),
                            DataCell(Text(entry[2])),
                            DataCell(
                              Text(entry[3]),
                              onLongPress: () {
                                final row = '${_formatDate(entry[0])}  ${entry[1]}  ${entry[2]}  ${entry[3]}';
                                Clipboard.setData(ClipboardData(text: row));
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                  content: Text('copied'.tr),
                                  duration: const Duration(seconds: 1),
                                  behavior: SnackBarBehavior.floating,
                                ));
                              },
                            ),
                          ],
                        );
                      }).toList(),
                    ),
                  ),
                ),
                  ],
                  );
                }),
              ] else ...[
                const SizedBox(height: 24),
                Icon(Icons.person_search, size: 56, color: Colors.grey.shade400),
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    'no_data'.tr,
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 15),
                  ),
                ),
                const SizedBox(height: 4),
                Center(
                  child: Text(
                    'select_employee_hint'.tr,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
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
    Navigator.pop(context);
    SharedPreferences prefs = await SharedPreferences.getInstance();
    if (_lang == "KZ") {
      prefs.setString(AppValues.LANG, "RU");
      Get.updateLocale(Locale(prefs.getString(AppValues.LANG)!));
      if (mounted) setState(() => _lang = prefs.getString(AppValues.LANG)!);
    } else if (_lang == "RU") {
      prefs.setString(AppValues.LANG, "KZ");
      Get.updateLocale(Locale(prefs.getString(AppValues.LANG)!));
      if (mounted) setState(() => _lang = prefs.getString(AppValues.LANG)!);
    }
  }

  _exit() => confirmAndLogout(context);

  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  Future<List<String>> _getEmployeesCached() async {
    if (_employeesCache != null) return _employeesCache!;
    final result = await getAllEmployees(context);
    if (mounted) _employeesCache = result;
    return result;
  }

  Widget _buildEventSummary(List<List<String>> data) {
    final counts = <String, int>{};
    for (final e in data) {
      if (e.length > 2 && e[2].isNotEmpty) {
        counts[e[2]] = (counts[e[2]] ?? 0) + 1;
      }
    }
    if (counts.isEmpty) return const SizedBox.shrink();
    final sorted = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: sorted.map((entry) {
          final lower = entry.key.toLowerCase();
          final isEntry = lower.contains('вход') || lower.contains('кіру') || lower.contains('entry');
          final isExit = lower.contains('выход') || lower.contains('шығу') || lower.contains('exit');
          final chipColor = isEntry
              ? Colors.green.shade700
              : isExit
                  ? AppColors.niceRed
                  : AppColors.mainColor;
          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Chip(
              avatar: Icon(
                isEntry ? Icons.login : isExit ? Icons.logout : Icons.event_note,
                size: 14,
                color: chipColor,
              ),
              label: Text('${entry.key}: ${entry.value}',
                  style: TextStyle(fontSize: 11, color: chipColor)),
              backgroundColor: chipColor.withOpacity(0.08),
              side: BorderSide(color: chipColor.withOpacity(0.3)),
              padding: EdgeInsets.zero,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildPresetChip(String label, VoidCallback onTap) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      onPressed: _loadingReport ? null : () {
        HapticFeedback.selectionClick();
        onTap();
      },
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
    );
  }

  String _formatDate(String raw) {
    try {
      final d = DateTime.parse(raw);
      return '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
    } catch (_) {
      return raw;
    }
  }

  bool _isToday(String raw) {
    try {
      final d = DateTime.parse(raw);
      final now = DateTime.now();
      return d.year == now.year && d.month == now.month && d.day == now.day;
    } catch (_) {
      return false;
    }
  }
}
