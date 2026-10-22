import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:se_mobile/functions/generate_excel.dart';
import 'package:se_mobile/requests/report_request.dart';
import 'package:se_mobile/requests/reportdate_request.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../functions/export_share.dart';
import '../functions/generate_csv.dart';
import '../utils/access_report.dart';
import '../utils/search_fold.dart';
import '../utils/lang.dart';
import '../utils/dimensions.dart';
import '../utils/variables.dart';
import '../variables.dart';
import '../widgets/access_log_list.dart';
import '../widgets/app_drawer.dart';
import '../widgets/custom_text.dart';
import '../utils/app_theme.dart';
import '../utils/load_problem.dart';
import '../widgets/load_error_view.dart';
import '../widgets/month_summary_card.dart';
import '../widgets/offline_notice.dart';


class MainPage1 extends StatefulWidget {
  final String fullName;
  final String job;

  /// Supplied inside the bottom-nav shell: enables the shared drawer and lets
  /// it switch tab. Null on the admin's view of somebody else.
  final ValueChanged<int>? onNavigate;

  /// Set by the admin panel to show somebody else's turnstile report. The
  /// profile drawer and logout are hidden then — they belong to the viewer,
  /// not the person being inspected.
  final String? employeeId;

  const MainPage1(
      {Key? key,
      required this.fullName,
      required this.job,
      this.onNavigate,
      this.employeeId})
      : super(key: key);

  @override
  State<MainPage1> createState() => _MainPage1State();
}

class _MainPage1State extends State<MainPage1> {
  late SharedPreferences prefs;
  final _recordCount = ValueNotifier<int>(0);
  final _dateRange = ValueNotifier<String>('');

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
      prefs.setString(AppValues.LANG, Lang.ru);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        centerTitle: true,
        leading: widget.onNavigate == null
            ? null
            : Builder(
                builder: (context) => IconButton(
                  icon: const Icon(Icons.menu),
                  tooltip: MaterialLocalizations.of(context).openAppDrawerTooltip,
                  onPressed: () => Scaffold.of(context).openDrawer(),
                ),
              ),
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
                if (value == 'send report exc') {
                  generateExcel(widget.fullName, reportsEntries, context);
                } else if (value == 'send report csv') {
                  generateTable(widget.fullName, reportsEntries, context);
                }
              },
            ),
          ),
          // Logout lives in the drawer now; the standalone variant (admin
          // viewing somebody else) gets neither, since it is not their session.
        ],
      ),
      drawer: widget.onNavigate == null
          ? null
          : AppDrawer(onNavigate: widget.onNavigate, currentIndex: 1),
      body: MainMenu1(
          recordCount: _recordCount,
          dateRange: _dateRange,
          fullName: widget.fullName,
          employeeId: widget.employeeId),
    );
  }

}

class MainMenu1 extends StatefulWidget {
  const MainMenu1(
      {Key? key,
      required this.recordCount,
      required this.dateRange,
      this.fullName,
      this.employeeId})
      : super(key: key);

  /// Чьи это проходы — по нему ищется последняя выгрузка.
  final String? fullName;
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
  LoadProblem? _problem;

  /// Что повторить по кнопке на экране ошибки: последний месяц или
  /// выбранный период — смотря что не загрузилось.
  late Future<void> Function() _retryLoad = _initData;

  /// По какое число вообще загружены проходы и есть ли они у этого человека.
  /// Пока сервер не ответил — null, и экран ведёт себя как раньше.
  AccessCoverage? _coverage;

  /// Показана копия, сохранённая на телефоне: когда её получили.
  DateTime? _cachedAt;

  /// Начало показанного периода, чтобы отличить «период позже выгрузки» от
  /// «в эти дни не проходил». null — показан весь отчёт целиком.
  DateTime? _shownPeriodStart;
  String _filterText = '';
  final _filterController = TextEditingController();

  @override
  void initState() {
    super.initState();
    startDate = DateTime.now();
    endDate = DateTime.now();
  }

  /// Потянули вниз — обновить и итоги месяца: заводим карточку заново.
  Key _summaryKey = UniqueKey();

  Future<void> _refresh() {
    setState(() => _summaryKey = UniqueKey());
    return _initData();
  }

  Future<void> _initData() async {
    _retryLoad = _initData;
    setState(() { _loadingReport = true; _initError = false; });
    final report = await getReportEntries(context);
    reportsEntries = report.entries;
    if (mounted) {
      setState(() {
        _loadingReport = false;
        _initError = report.isFailure;
        _problem = report.problem;
        _coverage = report.coverage ?? _coverage;
        _cachedAt = report.cachedAt;
        _shownPeriodStart = null;
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

  /// Пусто бывает по трём разным причинам, и человеку важно знать, по какой.
  ///
  /// Раньше на все три экран отвечал «нет данных, выберите период»: и тому,
  /// у кого проходов нет вовсе — выбирать период ему незачем, — и тому, кто
  /// открыл «Сегодня», а выгрузку из СКУД в последний раз приносили месяц
  /// назад. Второй случай выглядит как поломка, и объяснять его приходилось
  /// живым людям в ОИТиС.
  bool get _noRecordsAtAll =>
      _coverage != null && !_coverage!.employeeHasAny;

  bool get _periodBeyondData {
    final coverage = _coverage;
    final from = _shownPeriodStart;
    if (coverage == null || from == null) return false;
    return coverage.isBeyondData(from);
  }

  IconData get _emptyIcon {
    if (_noRecordsAtAll) return Icons.badge_outlined;
    if (_periodBeyondData) return Icons.update_outlined;
    return Icons.date_range_outlined;
  }

  String get _emptyTitle {
    if (_noRecordsAtAll) return 'no_passes_at_all'.tr;
    if (_periodBeyondData) return 'no_passes_yet'.tr;
    return 'no_data'.tr;
  }

  String get _emptyHint {
    if (_noRecordsAtAll) return 'no_passes_at_all_hint'.tr;
    if (_periodBeyondData) return _loadedUntilLine;
    if (_shownPeriodStart != null) return 'no_passes_in_period_hint'.tr;
    return 'select_period_hint'.tr;
  }

  /// «Проходы загружены по 20 августа» — одной строкой и той же формулировкой
  /// и в пустом списке, и над заполненным.
  String get _loadedUntilLine {
    final until = _coverage?.loadedUntil;
    if (until == null) return 'select_period_hint'.tr;
    return 'loaded_until'
        .trParams({'date': DateFormat('dd.MM.yyyy').format(until)});
  }

  /// Стоит ли предупредить, что отчёт отстаёт от сегодняшнего дня.
  ///
  /// Выгрузку приносят раз в месяц, поэтому «сегодня» в отчёте не бывает
  /// почти никогда. Молчать об этом — значит каждый раз объяснять заново.
  bool get _dataIsBehind {
    final behind = _coverage?.daysBehind;
    return behind != null && behind > 1;
  }

  Future<void> _loadDateReport() async {
    if (_loadingReport) return;
    if (startDate.isAfter(endDate)) {
      final tmp = startDate; startDate = endDate; endDate = tmp;
    }
    _retryLoad = _loadDateReport;
    setState(() {
      _loadingReport = true;
      _dateError = false;
      _initError = false;
      _filterText = '';
    });
    _filterController.clear();
    final report = await getReportDateEntries(
      context,
      DateFormat('yyyy-MM-dd').format(startDate),
      DateFormat('yyyy-MM-dd').format(endDate),
      employeeId: widget.employeeId,
    );
    reportsEntries = report.entries;
    if (!mounted) return;
    setState(() {
      _loadingReport = false;
      // Раньше неудача здесь не отмечалась, и экран говорил «за этот период
      // проходов нет» человеку, у которого просто не было связи.
      _initError = report.isFailure;
      _problem = report.problem;
      _coverage = report.coverage ?? _coverage;
      _cachedAt = report.cachedAt;
      _shownPeriodStart = startDate;
    });
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
      onRefresh: _refresh,
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
            // Сначала итог — ради него на экран и заходят чаще всего; список
            // проходов за любой период — ниже, как и был.
            MonthSummaryCard(
                key: _summaryKey, employeeId: widget.employeeId),
            const SizedBox(height: 4.0),
            // Две кнопки в строку не помещались даже на обычном телефоне:
            // «Просмотреть последний файл Excel» и «…CSV» шире 360 точек, и
            // вторая уходила за край. Не помещаются — встают одна под другой.
            Wrap(
              alignment: WrapAlignment.center,
              children: [
                TextButton.icon(
                  onPressed: () =>
                      openLatestExport(context, widget.fullName, 'xlsx'),
                  icon: const Icon(Icons.table_chart_outlined, size: 16),
                  label: SmallText(content: "see last Excel".tr),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: () =>
                      openLatestExport(context, widget.fullName, 'csv'),
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
                          Flexible(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(
                            '${startDate.day.toString().padLeft(2, '0')}.${startDate.month.toString().padLeft(2, '0')}.${startDate.year}',
                            style: TextStyle(
                              fontSize: 15.0,
                              color: _dateError ? Colors.red.shade700 : null,
                            ),
                          ))),
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
                          Flexible(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(
                            '${endDate.day.toString().padLeft(2, '0')}.${endDate.month.toString().padLeft(2, '0')}.${endDate.year}',
                            style: TextStyle(
                              fontSize: 15.0,
                              color: _dateError ? Colors.red.shade700 : null,
                            ),
                          ))),
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
            // Отчёт всегда отстаёт: выгрузку из СКУД приносят раз в месяц.
            // Строка снимает вопрос «почему сегодняшнего прохода не видно»
            // до того, как он задан.
            // Связи нет, а этот период уже загружали: показываем копию и
            // говорим, от какого она числа.
            if (!_loadingReport && _cachedAt != null)
              Padding(
                padding: EdgeInsets.only(bottom: Dimensions.height30 / 3),
                child: OfflineNotice(at: _cachedAt),
              ),
            if (!_loadingReport && _dataIsBehind)
              Padding(
                padding: EdgeInsets.only(bottom: Dimensions.height30 / 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline,
                        size: 15, color: context.mutedColor.withOpacity(0.7)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(_loadedUntilLine,
                          style: TextStyle(
                              fontSize: 12.5,
                              height: 1.35,
                              color: context.mutedColor)),
                    ),
                  ],
                ),
              ),
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
                            matchesQuery(cell, _filterText)))
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
            ] else if (!_loadingReport && _initError) ...[
              const SizedBox(height: 8),
              LoadErrorView(problem: _problem, onRetry: () => _retryLoad()),
            ] else if (!_loadingReport && !_hasData) ...[
              const SizedBox(height: 32),
              Icon(_emptyIcon, size: 56, color: context.mutedColor.withOpacity(0.55)),
              const SizedBox(height: 8),
              Text(
                _emptyTitle,
                textAlign: TextAlign.center,
                style: TextStyle(color: context.mutedColor, fontSize: 15),
              ),
              const SizedBox(height: 4),
              Text(
                _emptyHint,
                textAlign: TextAlign.center,
                // Без прозрачности. Это подпись, объясняющая пустой экран, —
                // ровно то, ради чего человек сюда и смотрит. На 0,55 её
                // контраст 2,1 при норме 4,5: в цеху и на солнце не читается.
                style: TextStyle(color: context.mutedColor, fontSize: 13),
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

}
