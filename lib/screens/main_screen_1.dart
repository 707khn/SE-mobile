import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:se_mobile/functions/generate_excel.dart';
import 'package:se_mobile/requests/report_request.dart';
import 'package:se_mobile/requests/reportdate_request.dart';
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

  /// When provided (e.g. inside the bottom-nav shell), the AppBar shows a back
  /// arrow running this callback, and the profile drawer moves to a trailing
  /// icon so it stays reachable.
  final VoidCallback? onBack;

  /// Set by the admin panel to show somebody else's turnstile report. The
  /// profile drawer and logout are hidden then — they belong to the viewer,
  /// not the person being inspected.
  final String? employeeId;

  const MainPage1(
      {Key? key,
      required this.fullName,
      required this.job,
      this.onBack,
      this.employeeId})
      : super(key: key);

  @override
  State<MainPage1> createState() => _MainPage1State();
}

class _MainPage1State extends State<MainPage1> {
  static String _lang = "";
  String? _login;
  late SharedPreferences prefs;
  final _recordCount = ValueNotifier<int>(0);
  final _dateRange = ValueNotifier<String>('');
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    initializeSharedPreferences();
  }

  @override
  void dispose() {
    _recordCount.dispose();
    _dateRange.dispose();
    super.dispose();
  }

  Future<void> initializeSharedPreferences() async {
    prefs = await SharedPreferences.getInstance();
    if (prefs.getString(AppValues.LANG) == null) {
      prefs.setString(AppValues.LANG, "RU");
    }
    final login = await SecureStorageHelper.instance.getLogin();
    setState(() {
      _lang = prefs.getString(AppValues.LANG)!;
      _login = login;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: AppColors.niceWhite,
      appBar: AppBar(
        centerTitle: true,
        leading: widget.onBack != null
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: widget.onBack,
              )
            : null,
        title: ValueListenableBuilder<String>(
          valueListenable: _dateRange,
          builder: (_, dateStr, __) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              BigText(content: "attendance report".tr, fontWeight: FontWeight.bold),
              if (dateStr.isNotEmpty)
                Text(
                  dateStr,
                  style: const TextStyle(fontSize: 11, color: Colors.white70),
                ),
            ],
          ),
        ),
        actions: [
          ValueListenableBuilder<int>(
            valueListenable: _recordCount,
            builder: (_, count, __) => PopupMenuButton<String>(
              icon: Icon(Icons.share, color: count > 0 ? null : Colors.white38),
              enabled: count > 0,
              tooltip: 'send_report_tooltip'.tr,
              itemBuilder: (_) => [
                PopupMenuItem(value: 'send report exc', child: Text('send report exc'.tr)),
                PopupMenuItem(value: 'send report csv', child: Text('send report csv'.tr)),
              ],
              onSelected: (value) {
                if (value == 'send report exc') generateExcel(reportsEntries, context);
                else if (value == 'send report csv') generateTable(reportsEntries, context);
              },
            ),
          ),
          // Viewing somebody else from the admin panel: neither the viewer's
          // profile nor logout belongs here.
          if (widget.employeeId != null)
            const SizedBox.shrink()
          // In tab mode the hamburger is replaced by the back arrow, so the
          // profile drawer opens from this trailing icon instead. Logout
          // stays on the standalone variant only — the Home tab already has it.
          else if (widget.onBack != null)
            IconButton(
              icon: const Icon(Icons.account_circle_outlined),
              tooltip: 'profile'.tr,
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
            )
          else
            IconButton(
              icon: const Icon(Icons.logout),
              tooltip: 'log_out_title'.tr,
              onPressed: _exit,
            ),
        ],
      ),
      drawer: widget.employeeId != null
          ? null
          : Theme(
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
      body: MainMenu1(
          recordCount: _recordCount,
          dateRange: _dateRange,
          employeeId: widget.employeeId),
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
}

class MainMenu1 extends StatefulWidget {
  const MainMenu1(
      {Key? key,
      required this.recordCount,
      required this.dateRange,
      this.employeeId})
      : super(key: key);

  final String? employeeId;
  final ValueNotifier<int> recordCount;
  final ValueNotifier<String> dateRange;

  @override
  State<MainMenu1> createState() => _MainMenu1State();
}

class _MainMenu1State extends State<MainMenu1> {
  late DateTime startDate;
  late DateTime endDate;
  bool _loadingReport = false;
  bool _dateError = false;
  bool _initError = false;
  String _filterText = '';
  final _filterController = TextEditingController();

  @override
  void initState() {
    super.initState();
    startDate = DateTime.now();
    endDate = DateTime.now();
  }

  Future<void> _initData() async {
    setState(() { _loadingReport = true; _initError = false; });
    reportsEntries = await getReportEntries(context);
    if (mounted) {
      setState(() {
        _loadingReport = false;
        _initError = reportsEntries.length == 1 && reportsEntries[0][0] == 'no';
      });
      if (_hasData) {
        widget.recordCount.value = reportsEntries.length;
        final today = DateFormat('dd.MM.yyyy').format(DateTime.now());
        widget.dateRange.value = today;
      }
    }
  }

  bool get _hasData =>
      reportsEntries.isNotEmpty &&
      !(reportsEntries.length == 1 &&
          (reportsEntries[0][0].isEmpty || reportsEntries[0][0] == 'no'));

  Future<void> _loadDateReport() async {
    if (_loadingReport) return;
    if (startDate.isAfter(endDate)) {
      final tmp = startDate; startDate = endDate; endDate = tmp;
    }
    setState(() { _loadingReport = true; _dateError = false; _filterText = ''; });
    _filterController.clear();
    reportsEntries = await getReportDateEntries(
      context,
      DateFormat('yyyy-MM-dd').format(startDate),
      DateFormat('yyyy-MM-dd').format(endDate),
      employeeId: widget.employeeId,
    );
    if (!mounted) return;
    setState(() => _loadingReport = false);
    if (_hasData) {
      widget.recordCount.value = reportsEntries.length;
      final fmt = DateFormat('dd.MM.yyyy');
      widget.dateRange.value = '${fmt.format(startDate)} — ${fmt.format(endDate)}';
      HapticFeedback.lightImpact();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${reportsEntries.length} ${'records_count'.tr}'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ));
    } else {
      widget.recordCount.value = 0;
      widget.dateRange.value = '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _initData,
      child: SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
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
                    _loadDateReport();
                  }),
                  const SizedBox(width: 6),
                  _buildPresetChip('last_7_days'.tr, () {
                    final now = DateTime.now();
                    setState(() { startDate = now.subtract(const Duration(days: 6)); endDate = now; _dateError = false; });
                    _loadDateReport();
                  }),
                  const SizedBox(width: 6),
                  _buildPresetChip('this_month'.tr, () {
                    final now = DateTime.now();
                    setState(() { startDate = DateTime(now.year, now.month, 1); endDate = now; _dateError = false; });
                    _loadDateReport();
                  }),
                  const SizedBox(width: 6),
                  _buildPresetChip('last_month'.tr, () {
                    final now = DateTime.now();
                    final first = DateTime(now.year, now.month - 1, 1);
                    final last = DateTime(now.year, now.month, 0);
                    setState(() { startDate = first; endDate = last; _dateError = false; });
                    _loadDateReport();
                  }),
                ],
              ),
            ),
            SizedBox(height: Dimensions.height30 / 5),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _loadingReport ? null : _loadDateReport,
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
                    const SizedBox(height: 4),
                    const SizedBox(height: 4),
                    if (filtered.isEmpty && _filterText.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Column(
                          children: [
                            Icon(Icons.search_off, size: 40, color: Colors.grey.shade400),
                            const SizedBox(height: 8),
                            Text(
                              '"$_filterText"',
                              style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    if (filtered.isNotEmpty || _filterText.isEmpty)
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
            ] else if (!_loadingReport && _initError) ...[
              const SizedBox(height: 32),
              Icon(Icons.wifi_off, size: 56, color: Colors.grey.shade400),
              const SizedBox(height: 8),
              Text(
                'load_error'.tr,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade500, fontSize: 15),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _initData,
                icon: const Icon(Icons.refresh),
                label: Text('refresh'.tr),
              ),
            ] else if (!_loadingReport && !_hasData) ...[
              const SizedBox(height: 32),
              Icon(Icons.date_range_outlined, size: 56, color: Colors.grey.shade400),
              const SizedBox(height: 8),
              Text(
                'no_data'.tr,
                style: TextStyle(color: Colors.grey.shade500, fontSize: 15),
              ),
              const SizedBox(height: 4),
              Text(
                'select_period_hint'.tr,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
              ),
            ],
            SizedBox(height: Dimensions.height30),
          ],
        ),
      ),
    ),
    );
  }

  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  String _formatDate(String raw) {
    try {
      final d = DateTime.parse(raw);
      return '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
    } catch (_) {
      return raw;
    }
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
          const Icon(Icons.access_time_filled, size: 13, color: AppColors.mainColor),
          const SizedBox(width: 4),
          Text(
            '${_fmtTime(first)} — ${_fmtTime(last)}  ($timeStr)',
            style: const TextStyle(fontSize: 12, color: AppColors.mainColor),
          ),
        ],
      ),
    );
  }

  String _fmtTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

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
