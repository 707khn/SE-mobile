import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:se_mobile/utils/logout_helper.dart';
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
        title: BigText(content: "attendance report".tr, fontWeight: FontWeight.bold),
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
                generateExcel(reportsEntries, context);
              } else if (value == 'send report csv') {
                generateTable(reportsEntries, context);
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
      body: const MainMenu1(),
    );
  }

  _changeLanguage() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    if (_lang == "KZ") {
      prefs.setString(AppValues.LANG, "RU");
      Get.updateLocale(Locale(prefs.getString(AppValues.LANG)!));
      setState(() {
        _lang = prefs.getString(AppValues.LANG)!;
      });
    } else if (_lang == "RU") {
      prefs.setString(AppValues.LANG, "KZ");
      Get.updateLocale(Locale(prefs.getString(AppValues.LANG)!));
      setState(() {
        _lang = prefs.getString(AppValues.LANG)!;
      });
    }
  }

  _exit() => confirmAndLogout(context);
}

class MainMenu1 extends StatefulWidget {
  const MainMenu1({Key? key}) : super(key: key);

  @override
  State<MainMenu1> createState() => _MainMenu1State();
}

class _MainMenu1State extends State<MainMenu1> {
  late DateTime startDate;
  late DateTime endDate;
  bool _loadingReport = false;

  @override
  void initState() {
    super.initState();
    startDate = DateTime.now();
    endDate = DateTime.now();
    _initData();
  }

  Future<void> _initData() async {
    setState(() => _loadingReport = true);
    reportsEntries = await getReportEntries(context);
    if (mounted) setState(() => _loadingReport = false);
  }

  bool get _hasData =>
      reportsEntries.isNotEmpty &&
      !(reportsEntries.length == 1 && reportsEntries[0][0].isEmpty);

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Container(
        padding: EdgeInsets.only(
          top: Dimensions.height30 / 2,
          left: Dimensions.width20,
          right: Dimensions.width20,
        ),
        child: Column(
          children: [
            const SizedBox(height: 4.0),
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
            SizedBox(height: Dimensions.height30 / 5),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _loadingReport
                    ? null
                    : () async {
                        setState(() => _loadingReport = true);
                        reportsEntries = await getReportDateEntries(
                          context,
                          DateFormat('dd.MM.yyyy').format(startDate),
                          DateFormat('dd.MM.yyyy').format(endDate),
                        );
                        if (!mounted) return;
                        setState(() => _loadingReport = false);
                        if (_hasData) {
                          HapticFeedback.lightImpact();
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('${reportsEntries.length} ${'records_count'.tr}'),
                              duration: const Duration(seconds: 2),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        }
                      },
                style: ElevatedButton.styleFrom(
                  padding: EdgeInsets.symmetric(vertical: Dimensions.height30 / 2),
                ),
                child: _loadingReport
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : MediumText(content: "show report".tr, fontWeight: FontWeight.bold, maxLines: 1),
              ),
            ),
            SizedBox(height: Dimensions.height30 / 3),
            if (!_loadingReport && _hasData) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'scroll to right'.tr,
                    style: const TextStyle(fontSize: 12.0, color: Colors.grey),
                  ),
                  Text(
                    '${reportsEntries.length} ${'records_count'.tr}',
                    style: TextStyle(fontSize: 12.0, color: Colors.grey.shade600),
                  ),
                ],
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
                        DataCell(Text(_formatDate(entry[0]))),
                        DataCell(Text(entry[1])),
                        DataCell(Text(entry[2])),
                        DataCell(Text(entry[3])),
                      ]);
                    }).toList(),
                  ),
                ),
              ),
            ] else if (!_loadingReport && !_hasData) ...[
              const SizedBox(height: 32),
              Icon(Icons.inbox_outlined, size: 56, color: Colors.grey.shade400),
              const SizedBox(height: 8),
              Text(
                'no_data'.tr,
                style: TextStyle(color: Colors.grey.shade500, fontSize: 15),
              ),
            ],
            SizedBox(height: Dimensions.height30),
          ],
        ),
      ),
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
}
