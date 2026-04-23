import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

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

  Future<void> _pickMonth() async {
    int selectedYear = _selectedDate.year;
    int selectedMonth = _selectedDate.month;

    await showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text('choose period'.tr),
          content: StatefulBuilder(
            builder: (context, setInnerState) {
              return SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        IconButton(
                          onPressed: () => setInnerState(() => selectedYear--),
                          icon: const Icon(Icons.arrow_back_ios),
                        ),
                        Text(
                          '$selectedYear',
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        IconButton(
                          onPressed: () => setInnerState(() => selectedYear++),
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
                        final isSelected = m == selectedMonth;
                        return GestureDetector(
                          onTap: () => setInnerState(() => selectedMonth = m),
                          child: Container(
                            margin: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              color: isSelected ? AppColors.mainColor : Colors.transparent,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Center(
                              child: Text(
                                DateFormat('MMM', 'ru').format(DateTime(selectedYear, m)),
                                style: TextStyle(
                                  color: isSelected ? Colors.white : Colors.black87,
                                  fontSize: 13,
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
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(Dimensions.width20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: ListTile(
                leading: const Icon(Icons.calendar_month, color: AppColors.mainColor),
                title: Text(
                  DateFormat('MMMM yyyy', 'ru').format(_selectedDate),
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                trailing: ElevatedButton(
                  onPressed: _pickMonth,
                  child: Text('choose period'.tr),
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
                      const Icon(Icons.info_outline, size: 48, color: Colors.grey),
                      SizedBox(height: Dimensions.height30 / 2),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.grey, fontSize: 16),
                      ),
                    ],
                  ),
                ),
              ),
            if (_payslip != null) ...[
              Card(
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
              SizedBox(height: Dimensions.height30 / 2),
              Card(
                elevation: 3,
                child: Padding(
                  padding: EdgeInsets.all(Dimensions.width20),
                  child: Row(
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
                ),
              ),
              SizedBox(height: Dimensions.height30),
            ],
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
                        style: const TextStyle(fontSize: 14),
                      ),
                    ],
                  ),
                )),
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'total'.tr,
                  style: TextStyle(fontWeight: FontWeight.bold, color: color),
                ),
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
