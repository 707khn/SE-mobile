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
  static DateTime _prevMonth() {
    final now = DateTime.now();
    return DateTime(now.year, now.month - 1);
  }

  DateTime _selectedDate = _prevMonth();
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
    final data = await getPayslip(
      context,
      _selectedDate.month.toString().padLeft(2, '0'),
      _selectedDate.year.toString(),
    );
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
    setState(() => _selectedDate = DateTime(_selectedDate.year, _selectedDate.month - 1));
    _fetchPayslip();
  }

  void _goToNextMonth() {
    setState(() => _selectedDate = DateTime(_selectedDate.year, _selectedDate.month + 1));
    _fetchPayslip();
  }

  void _sharePayslip() {
    if (_payslip == null) return;
    final buf = StringBuffer();
    buf.writeln(_payslip!.employee);
    buf.writeln(_payslip!.period);
    buf.writeln('');
    buf.writeln('${'accruals'.tr}: ${_numberFormat.format(_payslip!.totalAccruals)} ₸');
    buf.writeln('${'deductions'.tr}: ${_numberFormat.format(_payslip!.totalDeductions)} ₸');
    buf.writeln('${'net pay'.tr}: ${_numberFormat.format(_payslip!.netPay)} ₸');
    HapticFeedback.lightImpact();
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
                      childAspectRatio: 1.5,
                    ),
                    itemCount: 12,
                    itemBuilder: (ctx, i) {
                      final m = i + 1;
                      final isSelected = m == selMonth && selYear == _selectedDate.year;
                      final isFuture = isCurrentYear && m > now.month;
                      final isCurrent = m == now.month && selYear == now.year;
                      return GestureDetector(
                        onTap: isFuture ? null : () => setInner(() => selMonth = m),
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
                              DateFormat('MMM', 'ru').format(DateTime(selYear, m)),
                              style: TextStyle(
                                color: isSelected
                                    ? Colors.white
                                    : isFuture
                                        ? Colors.grey.shade400
                                        : isCurrent
                                            ? AppColors.mainColor
                                            : Colors.black87,
                                fontSize: 13,
                                fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
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
              // Month picker card
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
                          color: _isCurrentOrFutureMonth
                              ? Colors.grey.shade300
                              : AppColors.mainColor,
                        ),
                        onPressed: (_loading || _isCurrentOrFutureMonth) ? null : _goToNextMonth,
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
                    padding: EdgeInsets.all(32),
                    child: CircularProgressIndicator(color: AppColors.mainColor),
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
                        Text(_error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.grey, fontSize: 16)),
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
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold)),
                                    const SizedBox(height: 4),
                                    Text(_payslip!.period,
                                        style:
                                            const TextStyle(color: Colors.white70, fontSize: 14)),
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
                              color: Colors.grey.shade600,
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
                fontSize: 30,
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
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '▲ ${_numberFormat.format(ps.totalAccruals)} ₸',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                Text(
                  '▼ ${_numberFormat.format(ps.totalDeductions)} ₸',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ],
        ),
      ),
    );
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
            Text(title,
                style: TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 15, color: color)),
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
                      style: const TextStyle(color: Colors.grey, fontSize: 14))
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
                                        Text(item.name, style: const TextStyle(fontSize: 14))),
                                Text('${_numberFormat.format(item.amount)} ₸',
                                    style: const TextStyle(
                                        fontSize: 14, fontWeight: FontWeight.w500)),
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
                                        fontSize: 11, color: Colors.grey.shade500)),
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
                                  Text(item.name, style: const TextStyle(fontSize: 14))),
                          Text('${_numberFormat.format(item.amount)} ₸',
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w500)),
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
            const Text('Выплачено',
                style: TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 15, color: color)),
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
                          Text('${_numberFormat.format(item.amount)} ₸',
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w500)),
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
