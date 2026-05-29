import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../requests/payslip_request.dart';
import '../utils/colors.dart';
import '../utils/dimensions.dart';
import '../widgets/custom_text.dart';

sealed class _State {}
final class _Loading extends _State {
  // Non-null during automatic retry — shown as a subtitle under the spinner.
  final String? hint;
  _Loading([this.hint]);
}
final class _Error extends _State {
  final PayslipErrorKind kind;
  _Error(this.kind);
}
final class _Ready extends _State {
  final PayslipData data;
  _Ready(this.data);
}

class PayslipPage extends StatefulWidget {
  const PayslipPage({Key? key}) : super(key: key);
  @override
  State<PayslipPage> createState() => _PayslipPageState();
}

class _PayslipPageState extends State<PayslipPage> {
  static DateTime _defaultDate() {
    final now = DateTime.now();
    return DateTime(now.year, now.month - 1);
  }

  DateTime _selected = _defaultDate();
  _State _state = _Loading();
  final _fmt = NumberFormat('#,##0.00', 'ru_RU');

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() => _state = _Loading());

    // Show a hint after 5 s so the user knows the server is waking up.
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted && _state is _Loading) {
        setState(() => _state = _Loading('server_timeout'.tr));
      }
    });

    try {
      final data = await fetchPayslip(
        _selected.month.toString().padLeft(2, '0'),
        _selected.year.toString(),
      );
      if (mounted) setState(() => _state = _Ready(data));
    } on PayslipException catch (e) {
      if (mounted) setState(() => _state = _Error(e.kind));
    } catch (_) {
      if (mounted) setState(() => _state = _Error(PayslipErrorKind.network));
    }
  }

  bool get _isFutureMonth {
    final now = DateTime.now();
    return _selected.year > now.year ||
        (_selected.year == now.year && _selected.month >= now.month);
  }

  void _goPrev() {
    setState(() => _selected = DateTime(_selected.year, _selected.month - 1));
    _fetch();
  }

  void _goNext() {
    setState(() => _selected = DateTime(_selected.year, _selected.month + 1));
    _fetch();
  }

  void _share() {
    if (_state is! _Ready) return;
    final d = (_state as _Ready).data;
    final buf = StringBuffer()
      ..writeln(d.employee)
      ..writeln(d.period)
      ..writeln()
      ..writeln('${'accruals'.tr}:');
    for (final i in d.accruals) {
      buf.writeln('  ${i.name}: ${_fmt.format(i.amount)} ₸');
    }
    buf
      ..writeln('${'total'.tr}: ${_fmt.format(d.totalAccruals)} ₸')
      ..writeln()
      ..writeln('${'deductions'.tr}:');
    for (final i in d.deductions) {
      buf.writeln('  ${i.name}: ${_fmt.format(i.amount)} ₸');
    }
    buf
      ..writeln('${'total'.tr}: ${_fmt.format(d.totalDeductions)} ₸')
      ..writeln()
      ..writeln('${'net pay'.tr}: ${_fmt.format(d.netPay)} ₸');
    HapticFeedback.lightImpact();
    Share.share(buf.toString());
  }

  Future<void> _pickPeriod() async {
    int year = _selected.year;
    int month = _selected.month;
    final now = DateTime.now();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text('choose period'.tr),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios),
                      onPressed: year > now.year - 5 ? () => set(() => year--) : null,
                    ),
                    Text('$year',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    IconButton(
                      icon: const Icon(Icons.arrow_forward_ios),
                      onPressed: year < now.year ? () => set(() => year++) : null,
                    ),
                  ],
                ),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    childAspectRatio: 1.5,
                  ),
                  itemCount: 12,
                  itemBuilder: (_, i) {
                    final m = i + 1;
                    final isSelected = m == month && year == _selected.year;
                    final isFuture = year == now.year && m > now.month;
                    final isCurrent = m == now.month && year == now.year;
                    return GestureDetector(
                      onTap: isFuture ? null : () => set(() => month = m),
                      child: Container(
                        margin: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? AppColors.mainColor
                              : isFuture
                                  ? Colors.grey.shade100
                                  : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          border: isCurrent && !isSelected
                              ? Border.all(color: AppColors.mainColor.withOpacity(0.5))
                              : null,
                        ),
                        child: Center(
                          child: Text(
                            DateFormat('MMM', 'ru').format(DateTime(year, m)),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                              color: isSelected
                                  ? Colors.white
                                  : isFuture
                                      ? Colors.grey.shade400
                                      : isCurrent
                                          ? AppColors.mainColor
                                          : Colors.black87,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('cancel'.tr),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('show report'.tr),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true) {
      setState(() => _selected = DateTime(year, month));
      _fetch();
    }
  }

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('copied'.tr),
      duration: const Duration(seconds: 1),
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final loading = _state is _Loading;
    return Scaffold(
      appBar: AppBar(
        title: BigText(content: 'payslip'.tr, fontWeight: FontWeight.bold),
        centerTitle: true,
        actions: [
          if (_state is _Ready)
            IconButton(
              icon: const Icon(Icons.share),
              tooltip: 'share'.tr,
              onPressed: _share,
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'refresh'.tr,
            onPressed: loading ? null : _fetch,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _fetch,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.all(Dimensions.width20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _periodBar(loading),
              SizedBox(height: Dimensions.height30 / 2),
              switch (_state) {
                _Loading(hint: final hint) => Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(color: AppColors.mainColor),
                          if (hint != null) ...[
                            const SizedBox(height: 16),
                            Text(
                              hint,
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                _Error(kind: final k) => _errorView(k),
                _Ready(data: final d) => _dataView(d),
              },
            ],
          ),
        ),
      ),
    );
  }

  Widget _periodBar(bool disabled) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.chevron_left, color: AppColors.mainColor),
              onPressed: disabled ? null : _goPrev,
              tooltip: 'last_month'.tr,
            ),
            const Icon(Icons.calendar_month, color: AppColors.mainColor, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                DateFormat('MMMM yyyy', 'ru').format(_selected),
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
            ),
            IconButton(
              icon: Icon(
                Icons.chevron_right,
                color: _isFutureMonth ? Colors.grey.shade300 : AppColors.mainColor,
              ),
              onPressed: (disabled || _isFutureMonth) ? null : _goNext,
              tooltip: 'this_month'.tr,
            ),
            TextButton(
              onPressed: disabled ? null : _pickPeriod,
              child: Text('choose period'.tr, style: const TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorView(PayslipErrorKind kind) {
    final msg = switch (kind) {
      PayslipErrorKind.timeout => 'server_timeout'.tr,
      PayslipErrorKind.network => 'connection_error'.tr,
      PayslipErrorKind.notFound => 'payslip not found'.tr,
    };
    return Center(
      child: Padding(
        padding: EdgeInsets.all(Dimensions.height30),
        child: Column(
          children: [
            const Icon(Icons.receipt_long, size: 56, color: Colors.grey),
            SizedBox(height: Dimensions.height30 / 2),
            Text(
              msg,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey, fontSize: 16),
            ),
            SizedBox(height: Dimensions.height30 / 2),
            ElevatedButton.icon(
              onPressed: _fetch,
              icon: const Icon(Icons.refresh),
              label: Text('refresh'.tr),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dataView(PayslipData d) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: Column(
        key: ValueKey(d.period),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            onLongPress: () => _copy('${d.employee}\n${d.period}'),
            child: Card(
              color: AppColors.mainColor,
              child: Padding(
                padding: EdgeInsets.all(Dimensions.width20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      d.employee,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    SizedBox(height: Dimensions.height30 / 4),
                    Text(d.period, style: const TextStyle(color: Colors.white70, fontSize: 14)),
                    if (d.position.isNotEmpty) ...[
                      SizedBox(height: Dimensions.height30 / 8),
                      Text(d.position,
                          style: const TextStyle(color: Colors.white60, fontSize: 12)),
                    ],
                  ],
                ),
              ),
            ),
          ),
          SizedBox(height: Dimensions.height30 / 2),
          _section('accruals'.tr, d.accruals, d.totalAccruals, Colors.green.shade700),
          SizedBox(height: Dimensions.height30 / 2),
          _section('deductions'.tr, d.deductions, d.totalDeductions, AppColors.niceRed),
          if (d.paid.isNotEmpty) ...[
            SizedBox(height: Dimensions.height30 / 2),
            _paidSection(d),
          ],
          if (d.benefits.isNotEmpty) ...[
            SizedBox(height: Dimensions.height30 / 2),
            _simpleSection('payslip_benefits'.tr, d.benefits, Colors.blue.shade700),
          ],
          if (d.reference.isNotEmpty) ...[
            SizedBox(height: Dimensions.height30 / 2),
            _simpleSection('payslip_reference'.tr, d.reference, Colors.grey.shade600),
          ],
          SizedBox(height: Dimensions.height30 / 2),
          _netPayCard(d),
          SizedBox(height: Dimensions.height30),
        ],
      ),
    );
  }

  Widget _section(String title, List<PayslipItem> items, double total, Color color) {
    final sorted = [...items]..sort((a, b) => b.amount.compareTo(a.amount));
    return Card(
      child: Padding(
        padding: EdgeInsets.all(Dimensions.width20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(title,
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: color)),
                if (items.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text('${items.length}',
                        style: TextStyle(
                            fontSize: 12, fontWeight: FontWeight.bold, color: color)),
                  ),
              ],
            ),
            const Divider(),
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('no_records'.tr,
                    style: const TextStyle(color: Colors.grey, fontSize: 14)),
              )
            else
              ...sorted.map((item) {
                final pct = total > 0 ? (item.amount / total * 100) : 0.0;
                return GestureDetector(
                  onLongPress: () =>
                      _copy('${item.name}: ${_fmt.format(item.amount)} ₸'),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                                child: Text(item.name,
                                    style: const TextStyle(fontSize: 14))),
                            Text('${_fmt.format(item.amount)} ₸',
                                style: const TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w500)),
                          ],
                        ),
                        const SizedBox(height: 2),
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
                                    fontSize: 11, color: Colors.grey.shade500)),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              }),
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('total'.tr,
                    style: TextStyle(fontWeight: FontWeight.bold, color: color)),
                Text('${_fmt.format(total)} ₸',
                    style: TextStyle(fontWeight: FontWeight.bold, color: color)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _simpleSection(String title, List<PayslipItem> items, Color color) {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(Dimensions.width20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: color)),
            const Divider(),
            ...items.map((item) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                          child: Text(item.name,
                              style: const TextStyle(fontSize: 14))),
                      Text('${_fmt.format(item.amount)} ₸',
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w500)),
                    ],
                  ),
                )),
          ],
        ),
      ),
    );
  }

  Widget _paidSection(PayslipData d) {
    const color = AppColors.mainColor;
    return Card(
      child: Padding(
        padding: EdgeInsets.all(Dimensions.width20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Выплачено',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16, color: color)),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text('${d.paid.length}',
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.bold, color: color)),
                ),
              ],
            ),
            const Divider(),
            ...d.paid.map((item) => Padding(
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
                                style: const TextStyle(fontSize: 14)),
                            if (item.document.isNotEmpty)
                              Text(item.document,
                                  style: TextStyle(
                                      fontSize: 12, color: Colors.grey.shade500)),
                            if (item.date.isNotEmpty)
                              Text(item.date,
                                  style: TextStyle(
                                      fontSize: 12, color: Colors.grey.shade500)),
                          ],
                        ),
                      ),
                      Text('${_fmt.format(item.amount)} ₸',
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w500)),
                    ],
                  ),
                )),
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Итого',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, color: color)),
                Text('${_fmt.format(d.totalPaid)} ₸',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, color: color)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _netPayCard(PayslipData d) {
    return GestureDetector(
      onLongPress: () => _copy('${_fmt.format(d.netPay)} ₸'),
      child: Card(
        elevation: 3,
        child: Padding(
          padding: EdgeInsets.all(Dimensions.width20),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('net pay'.tr,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16)),
                  Text(
                    '${_fmt.format(d.netPay)} ₸',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                      color: AppColors.mainColor,
                    ),
                  ),
                ],
              ),
              if (d.debtEnd != 0.0) ...[
                const SizedBox(height: 8),
                const Divider(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('payslip_debt'.tr,
                        style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
                    Text('${_fmt.format(d.debtEnd)} ₸',
                        style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
                  ],
                ),
              ],
              if (d.totalAccruals > 0) ...[
                const SizedBox(height: 8),
                Builder(builder: (context) {
                  final deductPct =
                      (d.totalDeductions / d.totalAccruals * 100).clamp(0.0, 100.0);
                  return Column(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: 1.0 - deductPct / 100,
                          minHeight: 6,
                          backgroundColor: AppColors.niceRed.withOpacity(0.2),
                          valueColor: const AlwaysStoppedAnimation<Color>(
                              AppColors.mainColor),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '${'net pay'.tr}: ${(100 - deductPct).toStringAsFixed(1)}%',
                            style: const TextStyle(
                                fontSize: 11, color: AppColors.mainColor),
                          ),
                          Text(
                            '${'deductions'.tr}: ${deductPct.toStringAsFixed(1)}%',
                            style: TextStyle(
                                fontSize: 11,
                                color: AppColors.niceRed.withOpacity(0.8)),
                          ),
                        ],
                      ),
                    ],
                  );
                }),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
