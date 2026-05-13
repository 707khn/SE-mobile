import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../requests/payslip_request.dart';
import '../utils/colors.dart';
import '../utils/dimensions.dart';
import '../widgets/custom_text.dart';

class PayslipPage extends StatefulWidget {
  const PayslipPage({Key? key}) : super(key: key);

  @override
  State<PayslipPage> createState() => _PayslipPageState();
}

class _PayslipPageState extends State<PayslipPage> {
  DateTime _selectedDate = DateTime(DateTime.now().year, DateTime.now().month);
  PayslipData? _payslip;
  bool _loading = false;
  String? _error;

  final _numberFormat = NumberFormat('#,##0.00', 'ru_RU');

  @override
  void initState() {
    super.initState();
    _fetchPayslip();
  }

  Future<void> _fetchPayslip() async {
    setState(() {
      _loading = true;
      _error = null;
      _payslip = null;
    });

    final month = _selectedDate.month.toString().padLeft(2, '0');
    final year = _selectedDate.year.toString();
    final data = await getPayslip(context, month, year);

    if (!mounted) return;
    setState(() {
      _loading = false;
      if (data == null) {
        _error = 'payslip not found'.tr;
      } else {
        _payslip = data;
      }
    });
  }

  bool get _isCurrentOrFutureMonth {
    final now = DateTime.now();
    return _selectedDate.year > now.year ||
        (_selectedDate.year == now.year && _selectedDate.month >= now.month);
  }

  void _goToPrevMonth() {
    setState(() {
      _selectedDate = DateTime(_selectedDate.year, _selectedDate.month - 1);
    });
    _fetchPayslip();
  }

  void _goToNextMonth() {
    setState(() {
      _selectedDate = DateTime(_selectedDate.year, _selectedDate.month + 1);
    });
    _fetchPayslip();
  }

  void _sharePayslip() {
    if (_payslip == null) return;
    final buffer = StringBuffer();
    buffer.writeln(_payslip!.employee);
    buffer.writeln(_payslip!.period);
    buffer.writeln('');
    buffer.writeln('${'accruals'.tr}:');
    for (final item in _payslip!.accruals) {
      buffer.writeln('  ${item.name}: ${_numberFormat.format(item.amount)} ₸');
    }
    buffer.writeln('${'total'.tr}: ${_numberFormat.format(_payslip!.totalAccruals)} ₸');
    buffer.writeln('');
    buffer.writeln('${'deductions'.tr}:');
    for (final item in _payslip!.deductions) {
      buffer.writeln('  ${item.name}: ${_numberFormat.format(item.amount)} ₸');
    }
    buffer.writeln('${'total'.tr}: ${_numberFormat.format(_payslip!.totalDeductions)} ₸');
    buffer.writeln('');
    buffer.writeln('${'net pay'.tr}: ${_numberFormat.format(_payslip!.netPay)} ₸');
    HapticFeedback.lightImpact();
    Share.share(buffer.toString());
  }

  Future<void> _pickMonth() async {
    int selectedYear = _selectedDate.year;
    int selectedMonth = _selectedDate.month;
    final now = DateTime.now();

    await showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text('choose period'.tr),
          content: StatefulBuilder(
            builder: (context, setInnerState) {
              final isCurrentYear = selectedYear == now.year;
              final isFutureYear = selectedYear > now.year;
              return SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        IconButton(
                          onPressed: selectedYear > now.year - 5
                              ? () => setInnerState(() {
                                    selectedYear--;
                                    if (isFutureYear && selectedMonth > now.month) {
                                      selectedMonth = now.month;
                                    }
                                  })
                              : null,
                          icon: const Icon(Icons.arrow_back_ios),
                        ),
                        Text(
                          '$selectedYear',
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        IconButton(
                          onPressed: selectedYear < now.year
                              ? () => setInnerState(() => selectedYear++)
                              : null,
                          icon: const Icon(Icons.arrow_forward_ios),
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
                      itemBuilder: (ctx, index) {
                        final m = index + 1;
                        final isSelected = m == selectedMonth && selectedYear == _selectedDate.year;
                        final isFuture = isCurrentYear && m > now.month;
                        final isCurrentMonth = m == now.month && selectedYear == now.year;
                        return GestureDetector(
                          onTap: isFuture ? null : () => setInnerState(() => selectedMonth = m),
                          child: Container(
                            margin: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? AppColors.mainColor
                                  : isFuture
                                      ? Colors.grey.shade100
                                      : Colors.transparent,
                              borderRadius: BorderRadius.circular(8),
                              border: isCurrentMonth && !isSelected
                                  ? Border.all(color: AppColors.mainColor.withOpacity(0.5))
                                  : null,
                            ),
                            child: Center(
                              child: Text(
                                DateFormat('MMM', 'ru').format(DateTime(selectedYear, m)),
                                style: TextStyle(
                                  color: isSelected
                                      ? Colors.white
                                      : isFuture
                                          ? Colors.grey.shade400
                                          : isCurrentMonth
                                              ? AppColors.mainColor
                                              : Colors.black87,
                                  fontSize: 13,
                                  fontWeight: isCurrentMonth ? FontWeight.bold : FontWeight.normal,
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('cancel'.tr),
            ),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _selectedDate = DateTime(selectedYear, selectedMonth);
                });
                Navigator.pop(ctx);
                _fetchPayslip();
              },
              child: Text('show report'.tr),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: BigText(content: 'payslip'.tr, fontWeight: FontWeight.bold),
        centerTitle: true,
        actions: [
          if (_payslip != null)
            IconButton(
              icon: const Icon(Icons.share),
              tooltip: 'share'.tr,
              onPressed: _sharePayslip,
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
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.all(Dimensions.width20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.chevron_left, color: AppColors.mainColor),
                        onPressed: _loading ? null : _goToPrevMonth,
                        tooltip: 'last_month'.tr,
                      ),
                      const Icon(Icons.calendar_month, color: AppColors.mainColor, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          DateFormat('MMMM yyyy', 'ru').format(_selectedDate),
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.chevron_right,
                          color: _isCurrentOrFutureMonth ? Colors.grey.shade300 : AppColors.mainColor,
                        ),
                        onPressed: (_loading || _isCurrentOrFutureMonth) ? null : _goToNextMonth,
                        tooltip: 'this_month'.tr,
                      ),
                      TextButton(
                        onPressed: _loading ? null : _pickMonth,
                        child: Text('choose period'.tr, style: const TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: Dimensions.height30 / 2),
              if (_loading)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32.0),
                    child: CircularProgressIndicator(),
                  ),
                ),
              if (_error != null)
                Center(
                  child: Padding(
                    padding: EdgeInsets.all(Dimensions.height30),
                    child: Column(
                      children: [
                        const Icon(Icons.receipt_long, size: 56, color: Colors.grey),
                        SizedBox(height: Dimensions.height30 / 2),
                        Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.grey, fontSize: 16),
                        ),
                        SizedBox(height: Dimensions.height30 / 2),
                        ElevatedButton.icon(
                          onPressed: _fetchPayslip,
                          icon: const Icon(Icons.refresh),
                          label: Text('refresh'.tr),
                        ),
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
                GestureDetector(
                  onLongPress: () {
                    Clipboard.setData(ClipboardData(
                      text: '${_payslip!.employee}\n${_payslip!.period}',
                    ));
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text('copied'.tr),
                      duration: const Duration(seconds: 1),
                      behavior: SnackBarBehavior.floating,
                    ));
                  },
                  child: Card(
                    color: AppColors.mainColor,
                    child: Padding(
                      padding: EdgeInsets.all(Dimensions.width20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _payslip!.employee,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          SizedBox(height: Dimensions.height30 / 4),
                          Text(
                            _payslip!.period,
                            style: const TextStyle(color: Colors.white70, fontSize: 14),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                SizedBox(height: Dimensions.height30 / 2),
                _buildSection(
                  'accruals'.tr,
                  _payslip!.accruals,
                  _payslip!.totalAccruals,
                  Colors.green.shade700,
                ),
                SizedBox(height: Dimensions.height30 / 2),
                _buildSection(
                  'deductions'.tr,
                  _payslip!.deductions,
                  _payslip!.totalDeductions,
                  AppColors.niceRed,
                ),
                if (_payslip!.paid.isNotEmpty) ...[
                  SizedBox(height: Dimensions.height30 / 2),
                  _buildPaidSection(),
                ],
                if (_payslip!.benefits.isNotEmpty) ...[
                  SizedBox(height: Dimensions.height30 / 2),
                  _buildSimpleSection(
                    'Льготы',
                    _payslip!.benefits,
                    Colors.blue.shade700,
                  ),
                ],
                if (_payslip!.reference.isNotEmpty) ...[
                  SizedBox(height: Dimensions.height30 / 2),
                  _buildSimpleSection(
                    'Справочно',
                    _payslip!.reference,
                    Colors.grey.shade600,
                  ),
                ],
                SizedBox(height: Dimensions.height30 / 2),
                GestureDetector(
                  onLongPress: () {
                    Clipboard.setData(ClipboardData(
                      text: '${_numberFormat.format(_payslip!.netPay)} ₸',
                    ));
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text('copied'.tr),
                      duration: const Duration(seconds: 1),
                      behavior: SnackBarBehavior.floating,
                    ));
                  },
                  child: Card(
                    elevation: 3,
                    child: Padding(
                      padding: EdgeInsets.all(Dimensions.width20),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'net pay'.tr,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                              ),
                              Text(
                                '${_numberFormat.format(_payslip!.netPay)} ₸',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 18,
                                  color: AppColors.mainColor,
                                ),
                              ),
                            ],
                          ),
                          if (_payslip!.debtEnd != 0.0) ...[
                            const SizedBox(height: 8),
                            const Divider(),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'Долг предприятия',
                                  style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                                ),
                                Text(
                                  '${_numberFormat.format(_payslip!.debtEnd)} ₸',
                                  style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                                ),
                              ],
                            ),
                          ],
                          if (_payslip!.totalAccruals > 0) ...[
                            const SizedBox(height: 8),
                            Builder(builder: (context) {
                              final deductPct = (_payslip!.totalDeductions / _payslip!.totalAccruals * 100).clamp(0, 100);
                              return Column(
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(3),
                                    child: LinearProgressIndicator(
                                      value: 1.0 - (deductPct / 100),
                                      minHeight: 6,
                                      backgroundColor: AppColors.niceRed.withOpacity(0.2),
                                      valueColor: const AlwaysStoppedAnimation<Color>(AppColors.mainColor),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        '${'net pay'.tr}: ${(100 - deductPct).toStringAsFixed(1)}%',
                                        style: const TextStyle(fontSize: 11, color: AppColors.mainColor),
                                      ),
                                      Text(
                                        '${'deductions'.tr}: ${deductPct.toStringAsFixed(1)}%',
                                        style: TextStyle(fontSize: 11, color: AppColors.niceRed.withOpacity(0.8)),
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
                ),
                SizedBox(height: Dimensions.height30),
                      ],
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPaidSection() {
    final items = _payslip!.paid;
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
                const Text(
                  'Выплачено',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: color),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${items.length}',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color),
                  ),
                ),
              ],
            ),
            const Divider(),
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
                        Text(item.paymentType, style: const TextStyle(fontSize: 14)),
                        if (item.document.isNotEmpty)
                          Text(item.document, style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                        if (item.date.isNotEmpty)
                          Text(item.date, style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                      ],
                    ),
                  ),
                  Text(
                    '${_numberFormat.format(item.amount)} ₸',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            )),
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Итого', style: TextStyle(fontWeight: FontWeight.bold, color: color)),
                Text(
                  '${_numberFormat.format(_payslip!.totalPaid)} ₸',
                  style: const TextStyle(fontWeight: FontWeight.bold, color: color),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSimpleSection(String title, List<PayslipItem> items, Color color) {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(Dimensions.width20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: color),
            ),
            const Divider(),
            ...items.map((item) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(child: Text(item.name, style: const TextStyle(fontSize: 14))),
                  Text(
                    '${_numberFormat.format(item.amount)} ₸',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            )),
          ],
        ),
      ),
    );
  }

  Widget _buildSection(String title, List<PayslipItem> items, double total, Color color) {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(Dimensions.width20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  title,
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: color),
                ),
                if (items.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${items.length}',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color),
                    ),
                  ),
              ],
            ),
            const Divider(),
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'no_records'.tr,
                  style: const TextStyle(color: Colors.grey, fontSize: 14),
                ),
              )
            else
              ...([...items]..sort((a, b) => b.amount.compareTo(a.amount))).map((item) {
                final pct = total > 0 ? (item.amount / total * 100) : 0.0;
                return GestureDetector(
                  onLongPress: () {
                    Clipboard.setData(ClipboardData(
                      text: '${item.name}: ${_numberFormat.format(item.amount)} ₸',
                    ));
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text('copied'.tr),
                      duration: const Duration(seconds: 1),
                      behavior: SnackBarBehavior.floating,
                    ));
                  },
                  child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(item.name, style: const TextStyle(fontSize: 14)),
                          ),
                          Text(
                            '${_numberFormat.format(item.amount)} ₸',
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                          ),
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
                                valueColor: AlwaysStoppedAnimation<Color>(color.withOpacity(0.5)),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${pct.toStringAsFixed(1)}%',
                            style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                          ),
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
                Text('total'.tr, style: TextStyle(fontWeight: FontWeight.bold, color: color)),
                Text(
                  '${_numberFormat.format(total)} ₸',
                  style: TextStyle(fontWeight: FontWeight.bold, color: color),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
