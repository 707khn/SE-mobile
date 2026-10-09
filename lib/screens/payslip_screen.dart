import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../requests/payslip_request.dart';
import '../utils/colors.dart';
import '../utils/lang.dart';
import '../utils/dimensions.dart';
import '../widgets/app_drawer.dart';
import '../widgets/offline_notice.dart';
import '../widgets/custom_text.dart';
import '../widgets/skeleton.dart';
import '../utils/app_theme.dart';

class PayslipPage extends StatefulWidget {
  const PayslipPage({Key? key, this.onNavigate, this.employeeId, this.employeeName})
      : super(key: key);

  /// Supplied inside the bottom-nav shell: enables the shared drawer and
  /// lets it switch tab. Null on drill-down views, which keep a back arrow.
  final ValueChanged<int>? onNavigate;

  /// Set by the admin panel to show somebody else's payslip.
  final String? employeeId;
  final String? employeeName;

  @override
  State<PayslipPage> createState() => _PayslipPageState();
}

class _PayslipPageState extends State<PayslipPage> {
  static DateTime _prevMonth() {
    final now = DateTime.now();
    return DateTime(now.year, now.month - 1);
  }

  DateTime _selectedDate = _prevMonth();
  PayslipData? _payslip;
  bool _loading = false;
  String? _error;

  /// Месяцы, за которые листок есть. null — сервер ещё не ответил или не
  /// ответил вовсе: тогда экран ведёт себя как раньше и предлагает любой
  /// месяц.
  List<DateTime>? _periods;

  final _numberFormat = NumberFormat('#,##0.00', 'ru_RU');

  @override
  void initState() {
    super.initState();
    _start();
  }

  /// Сначала спрашиваем, за какие месяцы листок есть, и открываем самый
  /// свежий.
  ///
  /// Раньше экран открывался на прошлом месяце. Листки приносят с задержкой,
  /// и прошлый месяц почти никогда не тот, что уже в базе: 23 сентября
  /// прошлый месяц — август, а последний загруженный листок — за июль. То
  /// есть первое, что видел каждый, кто открыл «Расчётный лист», — «листок
  /// не найден».
  Future<void> _start() async {
    // Список месяцев — это лишний поход на сервер перед самим листком.
    // Показываем заглушку сразу, иначе экран на секунду остаётся пустым и
    // выглядит так, будто ничего не происходит.
    setState(() => _loading = true);
    final periods = await fetchPayslipPeriods(employeeId: widget.employeeId);
    if (!mounted) return;
    setState(() {
      _periods = periods;
      if (periods != null && periods.isNotEmpty) {
        _selectedDate = periods.first;
      }
    });
    await _fetchPayslip();
  }

  /// Есть ли листок за этот месяц. Пока список не пришёл — считаем, что есть:
  /// запрещать по незнанию хуже, чем сходить впустую.
  bool _hasSlip(DateTime month) {
    final periods = _periods;
    if (periods == null) return true;
    return periods
        .any((p) => p.year == month.year && p.month == month.month);
  }

  /// Самый свежий месяц с листком — чтобы назвать его в сообщении и
  /// перейти на него одним касанием.
  DateTime? get _latestSlip {
    final periods = _periods;
    if (periods == null || periods.isEmpty) return null;
    return periods.first;
  }

  /// За этот месяц листка нет, но за другие есть.
  bool get _missingButHaveOthers =>
      _error != null && !_hasSlip(_selectedDate) && _latestSlip != null;

  /// Листков нет вовсе — предлагать перебирать месяцы не за чем.
  bool get _noSlipsAtAll => _periods != null && _periods!.isEmpty;

  Future<void> _fetchPayslip() async {
    setState(() {
      _loading = true;
      _error = null;
      _payslip = null;
    });
    try {
      final data = await fetchPayslip(
        _selectedDate.month.toString().padLeft(2, '0'),
        _selectedDate.year.toString(),
        employeeId: widget.employeeId,
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _payslip = data;
      });
    } on PayslipException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.kind == PayslipErrorKind.notFound
            ? 'payslip not found'.tr
            : e.kind == PayslipErrorKind.timeout
                ? 'timeout'.tr
                : 'network_error'.tr;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'network_error'.tr;
      });
    }
  }

  bool get _isCurrentOrFutureMonth {
    final now = DateTime.now();
    return _selectedDate.year > now.year ||
        (_selectedDate.year == now.year && _selectedDate.month >= now.month);
  }

  /// Соседний месяц, в котором листок есть.
  ///
  /// Пока список месяцев неизвестен — просто соседний, как было. А когда
  /// известен, ходить по пустым незачем: между июнем и июлем лежит вся
  /// прошлая зима, и перелистывать её по одному месяцу — двенадцать нажатий
  /// до следующего листка.
  DateTime? _step(int direction) {
    final periods = _periods;
    if (periods == null) {
      return DateTime(_selectedDate.year, _selectedDate.month + direction);
    }
    // periods отсортирован от свежих к старым.
    for (final p in direction < 0 ? periods : periods.reversed) {
      if (direction < 0 && p.isBefore(_selectedDate)) return p;
      if (direction > 0 && p.isAfter(_selectedDate)) return p;
    }
    return null;
  }

  bool get _hasPrevMonth => _step(-1) != null;

  bool get _hasNextMonth =>
      _periods == null ? !_isCurrentOrFutureMonth : _step(1) != null;

  void _goToPrevMonth() {
    final target = _step(-1);
    if (target == null) return;
    setState(() => _selectedDate = target);
    _fetchPayslip();
  }

  void _goToNextMonth() {
    final target = _step(1);
    if (target == null) return;
    setState(() => _selectedDate = target);
    _fetchPayslip();
  }

  bool _sharing = false;

  static const _xlsxMime =
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
  static const _monthsRu = [
    'Январь', 'Февраль', 'Март', 'Апрель', 'Май', 'Июнь', 'Июль',
    'Август', 'Сентябрь', 'Октябрь', 'Ноябрь', 'Декабрь',
  ];

  /// «Поделиться» отправляет листок файлом Excel в вёрстке 1С — так его
  /// просят в бухгалтерии и в банке. Файл собирает сервер. Без связи —
  /// прежний текст с итогами, чтобы кнопка не молчала.
  Future<void> _sharePayslip() async {
    final payslip = _payslip;
    if (payslip == null || _sharing) return;
    HapticFeedback.lightImpact();
    final date = _selectedDate;
    setState(() => _sharing = true);
    try {
      final bytes = await downloadPayslipXlsx(
        date.month.toString().padLeft(2, '0'),
        date.year.toString(),
        employeeId: widget.employeeId,
      );
      if (!mounted) return;
      if (bytes != null) {
        // Своя папка во временных: перед каждой отправкой она чистится,
        // чтобы чужие и старые листки не копились на телефоне.
        final dir = Directory('${(await getTemporaryDirectory()).path}/payslips');
        if (await dir.exists()) await dir.delete(recursive: true);
        await dir.create(recursive: true);
        final name =
            'Расчетный листок ${_monthsRu[date.month - 1]} ${date.year}.xlsx';
        final file = File('${dir.path}/$name');
        await file.writeAsBytes(bytes, flush: true);
        await Share.shareXFiles(
          [XFile(file.path, mimeType: _xlsxMime, name: name)],
          subject: name,
        );
        return;
      }
    } catch (_) {
      // Не вышло с файлом — ниже отправится текст.
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('payslip_share_text'.tr)));
    _shareText(payslip);
  }

  void _shareText(PayslipData payslip) {
    final buf = StringBuffer();
    buf.writeln(payslip.employee);
    buf.writeln(payslip.period);
    buf.writeln('');
    buf.writeln('${'accruals'.tr}: ${_numberFormat.format(payslip.totalAccruals)} ₸');
    buf.writeln('${'deductions'.tr}: ${_numberFormat.format(payslip.totalDeductions)} ₸');
    buf.writeln('${'net pay'.tr}: ${_numberFormat.format(payslip.netPay)} ₸');
    Share.share(buf.toString());
  }

  Future<void> _pickMonth() async {
    int selYear = _selectedDate.year;
    int selMonth = _selectedDate.month;
    final now = DateTime.now();

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('choose period'.tr),
        content: StatefulBuilder(
          builder: (context, setInner) {
            final isCurrentYear = selYear == now.year;
            return SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        onPressed: selYear > now.year - 5
                            ? () => setInner(() => selYear--)
                            : null,
                        icon: const Icon(Icons.arrow_back_ios),
                      ),
                      Text('$selYear',
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      IconButton(
                        onPressed: selYear < now.year ? () => setInner(() => selYear++) : null,
                        icon: const Icon(Icons.arrow_forward_ios),
                      ),
                    ],
                  ),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 4,
                      // Высотой, а не пропорцией. При пропорции 1.5 ячейка на
                      // обычном телефоне выходила 40 точек — меньше
                      // сорока восьми, ниже которых палец промахивается, а в
                      // перчатке и подавно. Пропорция к тому же зависит от
                      // ширины экрана, то есть на узком было бы ещё меньше.
                      mainAxisExtent: 52,
                    ),
                    itemCount: 12,
                    itemBuilder: (ctx, i) {
                      final m = i + 1;
                      final isSelected = m == selMonth && selYear == _selectedDate.year;
                      final isFuture = isCurrentYear && m > now.month;
                      final isCurrent = m == now.month && selYear == now.year;
                      // Месяц без листка выглядит так же, как будущий: из
                      // шестидесяти предлагавшихся заполнены два, и выбирать
                      // вслепую значило шестьдесят раз получить «не найден».
                      final isEmpty = !isFuture && !_hasSlip(DateTime(selYear, m));
                      final isBlocked = isFuture || isEmpty;
                      return GestureDetector(
                        onTap: isBlocked ? null : () => setInner(() => selMonth = m),
                        child: Container(
                          margin: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? AppColors.mainColor
                                : isBlocked
                                    ? context.hairlineColor
                                    : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                            border: isCurrent && !isSelected
                                ? Border.all(color: AppColors.mainColor.withOpacity(0.5))
                                : null,
                          ),
                          child: Center(
                            child: Text(
                              DateFormat('MMM', Lang.dates).format(DateTime(selYear, m)),
                              style: TextStyle(
                                color: isSelected
                                    ? Colors.white
                                    : isBlocked
                                        ? context.mutedColor.withOpacity(0.55)
                                        : isCurrent
                                            ? context.accentColor
                                            : context.inkColor,
                                fontSize: 13,
                                fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  if (_periods != null) ...[
                    const SizedBox(height: 8),
                    Text('payslip_months_hint'.tr,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12, color: context.mutedColor)),
                  ],
                ],
              ),
            );
          },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('cancel'.tr)),
          ElevatedButton(
            onPressed: () {
              setState(() => _selectedDate = DateTime(selYear, selMonth));
              Navigator.pop(ctx);
              _fetchPayslip();
            },
            child: Text('show report'.tr),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: widget.onNavigate == null
          ? null
          : AppDrawer(onNavigate: widget.onNavigate, currentIndex: 2),
      appBar: AppBar(
        leading: widget.onNavigate == null
            ? null
            : Builder(
                builder: (context) => IconButton(
                  icon: const Icon(Icons.menu),
                  tooltip: MaterialLocalizations.of(context).openAppDrawerTooltip,
                  onPressed: () => Scaffold.of(context).openDrawer(),
                ),
              ),
        title: BigText(
            content: widget.employeeName ?? 'payslip'.tr,
            fontWeight: FontWeight.bold),
        centerTitle: true,
        actions: [
          if (_payslip != null)
            IconButton(
              icon: _sharing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.share),
              tooltip: 'share'.tr,
              onPressed: _sharing ? null : _sharePayslip,
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'refresh'.tr,
            onPressed: _loading ? null : _fetchPayslip,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _fetchPayslip,
        // Swipe left/right anywhere on the page to move between months.
        child: GestureDetector(
          onHorizontalDragEnd: _loading
              ? null
              : (details) {
                  final v = details.primaryVelocity ?? 0;
                  if (v > 250) {
                    _goToPrevMonth();
                  } else if (v < -250 && _hasNextMonth) {
                    _goToNextMonth();
                  }
                },
          child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.all(Dimensions.width20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OfflineNotice(at: _payslip?.cachedAt),
              // Month picker card
              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  child: Row(
                    children: [
                      IconButton(
                        icon: Icon(Icons.chevron_left, color: context.accentColor),
                        onPressed: (_loading || !_hasPrevMonth) ? null : _goToPrevMonth,
                        tooltip: 'last_month'.tr,
                      ),
                      Icon(Icons.calendar_month, color: context.accentColor, size: 20),
                      const SizedBox(width: 8),
                      // «Сентябрь 2026», а не «сентября 2026»: MMMM — родительный
                      // падеж, для даты внутри фразы. И в одну строку: на
                      // обычном телефоне шириной 360 точек «сентября»
                      // переносилось посреди слова.
                      Expanded(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            _monthTitle(_selectedDate),
                            maxLines: 1,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                          ),
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.chevron_right,
                          color: !_hasNextMonth
                              ? context.hairlineColor
                              : context.accentColor,
                        ),
                        onPressed: (_loading || !_hasNextMonth) ? null : _goToNextMonth,
                      ),
                      // Отступы у кнопки — поуже обычных: на телефоне шириной
                      // 320 точек с крупным шрифтом строка не помещалась, и
                      // место отнималось у названия месяца.
                      TextButton(
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          minimumSize: const Size(0, 40),
                        ),
                        onPressed: _loading ? null : _pickMonth,
                        child: Text('choose period'.tr, style: const TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: Dimensions.height30 / 2),

              if (_loading) const SkeletonPayslip(),

              if (_error != null)
                Center(
                  child: Padding(
                    padding: EdgeInsets.all(Dimensions.height30),
                    child: Column(
                      children: [
                        Icon(Icons.receipt_long, size: 56, color: context.mutedColor),
                        SizedBox(height: Dimensions.height30 / 2),
                        Text(_error!,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: context.mutedColor, fontSize: 15)),
                        // «Листка нет» без продолжения отправляет человека
                        // перебирать месяцы наугад. Последний, за который
                        // листок есть, известен — называем его и переходим
                        // одним касанием.
                        if (_missingButHaveOthers) ...[
                          SizedBox(height: Dimensions.height30 / 3),
                          Text(
                            'payslip_latest_is'.trParams({
                              'period': DateFormat('LLLL yyyy', Lang.dates)
                                  .format(_latestSlip!)
                            }),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: context.mutedColor, fontSize: 13),
                          ),
                          SizedBox(height: Dimensions.height30 / 2),
                          ElevatedButton.icon(
                            onPressed: () {
                              setState(() => _selectedDate = _latestSlip!);
                              _fetchPayslip();
                            },
                            icon: const Icon(Icons.receipt_long_outlined),
                            label: Text('payslip_open_latest'.tr),
                          ),
                        ] else if (_noSlipsAtAll) ...[
                          SizedBox(height: Dimensions.height30 / 3),
                          Text(
                            'payslip_none_at_all'.tr,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: context.mutedColor, fontSize: 13),
                          ),
                        ] else ...[
                          SizedBox(height: Dimensions.height30 / 2),
                          ElevatedButton.icon(
                            onPressed: _fetchPayslip,
                            icon: const Icon(Icons.refresh),
                            label: Text('refresh'.tr),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: _payslip == null
                    ? const SizedBox.shrink()
                    : Column(
                        key: ValueKey(_payslip!.period),
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Header: employee + period
                          GestureDetector(
                            onLongPress: () {
                              Clipboard.setData(ClipboardData(
                                  text: '${_payslip!.employee}\n${_payslip!.period}'));
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                content: Text('copied'.tr),
                                duration: const Duration(seconds: 1),
                                behavior: SnackBarBehavior.floating,
                              ));
                            },
                            child: Card(
                              color: AppColors.mainColor,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12)),
                              child: Padding(
                                padding: EdgeInsets.all(Dimensions.width20),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(_payslip!.employee,
                                        style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 15,
                                            fontWeight: FontWeight.bold)),
                                    const SizedBox(height: 4),
                                    Text(_payslip!.period,
                                        style:
                                            const TextStyle(color: Colors.white70, fontSize: 13)),
                                    if (_payslip!.position.isNotEmpty ||
                                        _payslip!.department.isNotEmpty) ...[
                                      const SizedBox(height: 2),
                                      Text(
                                        [_payslip!.position, _payslip!.department]
                                            .where((s) => s.isNotEmpty)
                                            .join(' · '),
                                        style:
                                            const TextStyle(color: Colors.white54, fontSize: 12),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                          SizedBox(height: Dimensions.height30 / 2),

                          // Summary: net pay gradient card
                          _buildNetPayCard(),
                          SizedBox(height: Dimensions.height30 / 2),

                          // Accruals (expanded)
                          _buildExpandableSection(
                            title: 'accruals'.tr,
                            items: _payslip!.accruals,
                            total: _payslip!.totalAccruals,
                            color: Colors.green.shade700,
                            initiallyExpanded: true,
                          ),
                          SizedBox(height: Dimensions.height30 / 2),

                          // Deductions (expanded)
                          _buildExpandableSection(
                            title: 'deductions'.tr,
                            items: _payslip!.deductions,
                            total: _payslip!.totalDeductions,
                            color: AppColors.niceRed,
                            initiallyExpanded: true,
                          ),

                          if (_payslip!.paid.isNotEmpty) ...[
                            SizedBox(height: Dimensions.height30 / 2),
                            _buildPaidSection(),
                          ],
                          if (_payslip!.benefits.isNotEmpty) ...[
                            SizedBox(height: Dimensions.height30 / 2),
                            _buildSimpleExpandable(
                              title: 'payslip_benefits'.tr,
                              items: _payslip!.benefits,
                              color: Colors.blue.shade700,
                            ),
                          ],
                          if (_payslip!.reference.isNotEmpty) ...[
                            SizedBox(height: Dimensions.height30 / 2),
                            _buildSimpleExpandable(
                              title: 'payslip_reference'.tr,
                              items: _payslip!.reference,
                              color: context.mutedColor,
                            ),
                          ],
                          SizedBox(height: Dimensions.height30),
                        ],
                      ),
              ),
            ],
          ),
          ),
        ),
      ),
    );
  }

  Widget _buildNetPayCard() {
    final ps = _payslip!;
    final deductPct = ps.totalAccruals > 0
        ? (ps.totalDeductions / ps.totalAccruals * 100).clamp(0.0, 100.0)
        : 0.0;
    return GestureDetector(
      onLongPress: () {
        Clipboard.setData(ClipboardData(text: '${_numberFormat.format(ps.netPay)} ₸'));
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('copied'.tr),
          duration: const Duration(seconds: 1),
          behavior: SnackBarBehavior.floating,
        ));
      },
      child: Container(
        padding: EdgeInsets.all(Dimensions.width20),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [AppColors.mainColor, AppColors.gradientColor2],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: AppColors.mainColor.withOpacity(0.3),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          children: [
            Text(
              'net pay'.tr,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 6),
            Text(
              '${_numberFormat.format(ps.netPay)} ₸',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            if (ps.debtEnd != 0.0) ...[
              const SizedBox(height: 4),
              Text(
                '${'payslip_debt'.tr}: ${_numberFormat.format(ps.debtEnd)} ₸',
                style: const TextStyle(color: Colors.white60, fontSize: 12),
              ),
            ],
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: 1.0 - deductPct / 100,
                minHeight: 6,
                backgroundColor: Colors.white24,
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            ),
            const SizedBox(height: 6),
            // Две суммы в строку: с крупным шрифтом на узком телефоне они
            // не помещались — ужимаются, а не уходят за край.
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      '▲ ${_numberFormat.format(ps.totalAccruals)} ₸',
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      '▼ ${_numberFormat.format(ps.totalDeductions)} ₸',
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _monthTitle(DateTime month) {
    final text = DateFormat('LLLL yyyy', Lang.dates).format(month);
    return text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);
  }

  Widget _buildExpandableSection({
    required String title,
    required List<PayslipItem> items,
    required double total,
    required Color color,
    bool initiallyExpanded = false,
  }) {
    final sorted = ([...items]..sort((a, b) => b.amount.compareTo(a.amount)));
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        tilePadding: EdgeInsets.symmetric(
            horizontal: Dimensions.width20, vertical: 4),
        title: Row(
          children: [
            Flexible(child: Text(title,
                style: TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 15, color: color))),
            const SizedBox(width: 8),
            if (items.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('${items.length}',
                    style: TextStyle(
                        fontSize: 11, fontWeight: FontWeight.bold, color: color)),
              ),
          ],
        ),
        trailing: Text(
          '${_numberFormat.format(total)} ₸',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: color),
        ),
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
                Dimensions.width20, 0, Dimensions.width20, Dimensions.width20),
            child: Column(
              children: [
                const Divider(height: 1),
                const SizedBox(height: 8),
                if (items.isEmpty)
                  Text('no_records'.tr,
                      style: TextStyle(color: context.mutedColor, fontSize: 13))
                else
                  ...sorted.map((item) {
                    final pct = total > 0 ? (item.amount / total * 100) : 0.0;
                    return GestureDetector(
                      onLongPress: () {
                        Clipboard.setData(ClipboardData(
                            text: '${item.name}: ${_numberFormat.format(item.amount)} ₸'));
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text('copied'.tr),
                          duration: const Duration(seconds: 1),
                          behavior: SnackBarBehavior.floating,
                        ));
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                    child:
                                        Text(item.name, style: const TextStyle(fontSize: 13))),
                                Text('${_numberFormat.format(item.amount)} ₸',
                                    style: const TextStyle(
                                        fontSize: 13, fontWeight: FontWeight.w500)),
                              ],
                            ),
                            const SizedBox(height: 3),
                            Row(
                              children: [
                                Expanded(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(2),
                                    child: LinearProgressIndicator(
                                      value: pct / 100,
                                      minHeight: 3,
                                      backgroundColor: color.withOpacity(0.1),
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                          color.withOpacity(0.5)),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text('${pct.toStringAsFixed(1)}%',
                                    style: TextStyle(
                                        fontSize: 11, color: context.mutedColor)),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSimpleExpandable({
    required String title,
    required List<PayslipItem> items,
    required Color color,
  }) {
    final total = items.fold(0.0, (s, e) => s + e.amount);
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: false,
        tilePadding:
            EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 4),
        title: Text(title,
            style: TextStyle(
                fontWeight: FontWeight.bold, fontSize: 15, color: color)),
        trailing: Text(
          '${_numberFormat.format(total)} ₸',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: color),
        ),
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
                Dimensions.width20, 0, Dimensions.width20, Dimensions.width20),
            child: Column(
              children: [
                const Divider(height: 1),
                const SizedBox(height: 8),
                ...items.map((item) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                              child:
                                  Text(item.name, style: const TextStyle(fontSize: 13))),
                          Text('${_numberFormat.format(item.amount)} ₸',
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w500)),
                        ],
                      ),
                    )),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPaidSection() {
    final items = _payslip!.paid;
    const color = AppColors.mainColor;
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: false,
        tilePadding:
            EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 4),
        title: Row(
          children: [
            Flexible(child: Text('payslip_paid'.tr,
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 15, color: color))),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: color.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text('${items.length}',
                  style: const TextStyle(
                      fontSize: 11, fontWeight: FontWeight.bold, color: color)),
            ),
          ],
        ),
        trailing: Text(
          '${_numberFormat.format(_payslip!.totalPaid)} ₸',
          style: const TextStyle(
              fontWeight: FontWeight.bold, fontSize: 13, color: color),
        ),
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
                Dimensions.width20, 0, Dimensions.width20, Dimensions.width20),
            child: Column(
              children: [
                const Divider(height: 1),
                const SizedBox(height: 8),
                ...items.map((item) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(item.paymentType,
                                    style: const TextStyle(fontSize: 13)),
                                if (item.document.isNotEmpty)
                                  Text(item.document,
                                      style: TextStyle(
                                          fontSize: 12, color: context.mutedColor)),
                                if (item.date.isNotEmpty)
                                  Text(item.date,
                                      style: TextStyle(
                                          fontSize: 12, color: context.mutedColor)),
                              ],
                            ),
                          ),
                          Text('${_numberFormat.format(item.amount)} ₸',
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w500)),
                        ],
                      ),
                    )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
