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
import 'package:se_mobile/screens/attendance_screen.dart';
import 'package:se_mobile/screens/menu_screen.dart';
import 'package:se_mobile/screens/payslip_screen.dart';
import 'package:se_mobile/screens/start_screen.dart';
import 'package:se_mobile/utils/logout_helper.dart';
import 'package:se_mobile/utils/secure_storage_helper.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../functions/generate_csv.dart';
import '../requests/reportdate_request.dart';
import '../utils/colors.dart';
import '../utils/lang.dart';
import '../utils/search_fold.dart';
import '../utils/dimensions.dart';
import '../utils/variables.dart';
import '../widgets/access_log_list.dart';
import '../widgets/app_drawer.dart';
import '../widgets/custom_text.dart';
import '../widgets/icon_button_drawer.dart';
import '../utils/app_theme.dart';
import '../utils/load_problem.dart';
import '../widgets/load_error_view.dart';

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
  LoadProblem? _problem;
  List<String>? _employeesCache;
  bool _employeesCacheLoading = false;
  String _filterText = '';
  final _filterController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    startDate = DateTime(now.year, now.month, 1);
    endDate = now;
    _initPrefs();
    employeeController.addListener(() {
      setState(() {
        searchText = employeeController.text;
        // Начальник ищет подчинённого по фамилии, а на русской раскладке
        // «Асқаров» не набрать: раскладку не спрашиваем.
        filteredEmployees = allEmployees
            .where((e) => matchesQuery(e, employeeController.text))
            .toList();
      });
    });
  }

  Future<void> _initPrefs() async {
    prefs = await SharedPreferences.getInstance();
    // Умолчания здесь нет намеренно. Прежде этот экран при пустой настройке
    // записывал «KZ», а main.dart считал умолчанием русский, — и язык
    // зависел от того, какой экран открыли первым.
    final savedEmployees = prefs.getStringList("emp_snames");
    final login = await SecureStorageHelper.instance.getLogin();
    setState(() {
      _lang = Lang.code(prefs.getString(AppValues.LANG));
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

  /// Отчёт по сотруднику не пришёл. Раньше этот случай попадал в «нет
  /// данных — выберите сотрудника» — хотя сотрудник как раз выбран.
  bool get _loadFailed =>
      reportsEntries.length == 1 &&
      reportsEntries[0].isNotEmpty &&
      reportsEntries[0][0] == 'no';

  /// Повтор по кнопке на экране ошибки: тот же сотрудник, те же даты.
  Future<void> _retryEmployeeReport() async {
    setState(() => _loadingReport = true);
    final data = await getEmployeeDate(
      context,
      DateFormat('yyyy-MM-dd').format(startDate),
      DateFormat('yyyy-MM-dd').format(endDate),
    );
    if (!mounted) return;
    setState(() {
      _loadingReport = false;
      _problem = data.problem;
      reportsEntries = data.entries;
      // Строка выгрузки этого сотрудника — последняя: заменяем неудачную.
      if (reportsEntriesForMsg.isNotEmpty) {
        reportsEntriesForMsg[reportsEntriesForMsg.length - 1] = data.entries;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu),
            tooltip: MaterialLocalizations.of(context).openAppDrawerTooltip,
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
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
      drawer: const AppDrawer(),
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
                            color: _dateError ? Colors.red.shade700 : context.mutedColor,
                            width: _dateError ? 1.5 : 1.0,
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.calendar_today, size: 16,
                                color: _dateError ? Colors.red.shade700 : context.mutedColor),
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
                          Text('—', style: TextStyle(color: isInvalid ? Colors.red.shade700 : context.mutedColor)),
                          Text(
                            isInvalid ? '!' : '$diff ${'days_short'.tr}',
                            style: TextStyle(
                              fontSize: 11,
                              color: isInvalid ? Colors.red.shade700 : context.mutedColor,
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
                            color: _dateError ? Colors.red.shade700 : context.mutedColor,
                            width: _dateError ? 1.5 : 1.0,
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.calendar_today, size: 16,
                                color: _dateError ? Colors.red.shade700 : context.mutedColor),
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
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: context.accentColor,
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
                      // The dialog lives on its own route, so it needs local
                      // state — the page's setState would not rebuild it.
                      return StatefulBuilder(
                        builder: (context, setDialogState) => AlertDialog(
                        title: TextField(
                          controller: employeeController,
                          autofocus: true,
                          onChanged: (value) {
                            setDialogState(() {
                              searchText = value;
                              filteredEmployees = allEmployees
                                  .where((e) => matchesQuery(e, value))
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
                                      setDialogState(() {
                                        searchText = '';
                                        filteredEmployees = allEmployees;
                                      });
                                    },
                                  )
                                : null,
                          ),
                        ),
                        // A single bounded scrollable: nesting a shrink-wrapped
                        // ListView inside a SingleChildScrollView left the list
                        // unable to scroll to its last entries.
                        content: SizedBox(
                            width: double.maxFinite,
                            height: MediaQuery.of(context).size.height * 0.4,
                            child: FutureBuilder(
                              future: _getEmployeesCached(),
                              builder: (BuildContext context, snapshot) {
                                if (snapshot.hasData) {
                                  final raw = snapshot.data!;
                                  // Список не пришёл — так и говорим, с
                                  // повтором, а не «записей нет». Повтор —
                                  // просто перерисовка: неудача не
                                  // запоминается, и список запросится снова.
                                  if (raw.length == 1 && raw[0] == 'no') {
                                    return LoadErrorView(
                                      onRetry: () => setDialogState(() {}),
                                    );
                                  }
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
                                        style: TextStyle(color: context.mutedColor),
                                      ),
                                    );
                                  }
                                  return ListView(
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
                                            DateFormat('yyyy-MM-dd').format(startDate),
                                            DateFormat('yyyy-MM-dd').format(endDate),
                                          );
                                          reportsEntries = data.entries;
                                          _problem = data.problem;
                                          reportsEntriesForMsg.add(data.entries);
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
                                } else {
                                  return LoadErrorView(
                                    problem: snapshot.hasError
                                        ? problemOfAny(snapshot.error!)
                                        : null,
                                    onRetry: () => setDialogState(() {}),
                                  );
                                }
                              },
                            ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: Text('cancel'.tr),
                          ),
                        ],
                      ),
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
                          leading: _buildInitialsAvatar(employees[index], index),
                          title: Text(employees[index]),
                          trailing: Icon(Icons.swipe_left, size: 16, color: context.mutedColor),
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
                          Icon(Icons.info_outline, color: context.accentColor),
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
                      Icon(Icons.info_outline, size: 16, color: context.mutedColor),
                      const SizedBox(width: 6),
                      Text(
                        'info_hint'.tr,
                        style: TextStyle(fontSize: 13, color: context.mutedColor),
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
                        Icon(Icons.person_outline, size: 16, color: context.accentColor),
                        const SizedBox(width: 6),
                        Text(
                          '${'viewing_employee'.tr} ${employees.last}',
                          style: TextStyle(
                            fontSize: 13,
                            color: context.accentColor,
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
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _filterText.isEmpty
                              ? '${reportsEntries.length} ${'records_count'.tr}'
                              : '${filtered.length}/${reportsEntries.length} ${'records_count'.tr}',
                          style: TextStyle(fontSize: 12.0, color: context.mutedColor),
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
                          child: Padding(
                            padding: EdgeInsets.all(2),
                            child: Icon(Icons.copy_outlined, size: 14, color: context.mutedColor),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                _buildWorkSummary(filtered),
                _buildEventSummary(filtered),
                const SizedBox(height: 4),
                if (filtered.isEmpty && _filterText.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Column(
                      children: [
                        Icon(Icons.search_off, size: 40, color: context.mutedColor.withOpacity(0.55)),
                        const SizedBox(height: 8),
                        Text(
                          '"$_filterText"',
                          style: TextStyle(color: context.mutedColor, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                if (filtered.isNotEmpty || _filterText.isEmpty)
                  AccessLogList(entries: filtered),
                  ],
                  );
                }),
              ] else if (_loadFailed) ...[
                const SizedBox(height: 8),
                LoadErrorView(problem: _problem, onRetry: _retryEmployeeReport),
              ] else ...[
                const SizedBox(height: 24),
                Icon(Icons.person_search, size: 56, color: context.mutedColor.withOpacity(0.55)),
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    'no_data'.tr,
                    style: TextStyle(color: context.mutedColor, fontSize: 15),
                  ),
                ),
                const SizedBox(height: 4),
                Center(
                  child: Text(
                    'select_employee_hint'.tr,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.mutedColor, fontSize: 13),
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
    final prefs = await SharedPreferences.getInstance();
    final next = Lang.isKazakh(_lang) ? Lang.ru : Lang.kk;
    await prefs.setString(AppValues.LANG, next);
    Get.updateLocale(Locale(next));
    if (mounted) setState(() => _lang = next);
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
    // Неудачу («no») не запоминаем: иначе список оставался пустым до
    // перезапуска приложения, и повторно открыть его было бесполезно.
    final failed = result.length == 1 && result[0] == 'no';
    if (mounted && !failed) _employeesCache = result;
    return result;
  }

  static const _avatarColors = [
    Color(0xFF1565C0), Color(0xFF2E7D32), Color(0xFF6A1B9A),
    Color(0xFFE65100), Color(0xFF00695C), Color(0xFFC62828),
    Color(0xFF4527A0), Color(0xFF283593),
  ];

  Widget _buildInitialsAvatar(String name, int index) {
    final parts = name.trim().split(RegExp(r'\s+'));
    final initials = parts.length >= 2
        ? '${parts[0][0]}${parts[1][0]}'.toUpperCase()
        : name.isNotEmpty ? name[0].toUpperCase() : '?';
    final color = _avatarColors[index % _avatarColors.length];
    return CircleAvatar(
      radius: 18,
      backgroundColor: color,
      child: Text(
        initials,
        style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
      ),
    );
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
      // No inline style: the chip theme governs size and colour.
      label: Text(label),
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

  Widget _buildWorkSummary(List<List<String>> data) {
    DateTime? first;
    DateTime? last;
    for (final e in data) {
      if (e.length < 2 || e[0].isEmpty || e[1].isEmpty) continue;
      try {
        final dt = DateTime.parse('${e[0]} ${e[1]}');
        if (first == null || dt.isBefore(first)) first = dt;
        if (last == null || dt.isAfter(last)) last = dt;
      } catch (_) {}
    }
    if (first == null || last == null || first == last) return const SizedBox.shrink();
    final span = last.difference(first);
    final h = span.inHours;
    final m = span.inMinutes % 60;
    final timeStr = h > 0 ? '${h}h ${m}m' : '${m}m';
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: Row(
        children: [
          Icon(Icons.access_time_filled, size: 13, color: context.accentColor),
          const SizedBox(width: 4),
          Text(
            '${_fmtTime(first)} — ${_fmtTime(last)}  ($timeStr)',
            style: TextStyle(fontSize: 12, color: context.accentColor),
          ),
        ],
      ),
    );
  }

  String _fmtTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

}
