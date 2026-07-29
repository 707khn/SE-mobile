import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:share_plus/share_plus.dart';

import '../requests/leave_request.dart';
import '../utils/colors.dart';
import '../utils/dimensions.dart';
import '../widgets/app_drawer.dart';
import '../widgets/custom_text.dart';

class LeavePage extends StatefulWidget {
  const LeavePage({Key? key, this.onNavigate, this.employeeId}) : super(key: key);

  /// Set by the admin panel to show somebody else's leave.
  final String? employeeId;

  /// Supplied inside the bottom-nav shell: enables the shared drawer and
  /// lets it switch tab. Null on drill-down views, which keep a back arrow.
  final ValueChanged<int>? onNavigate;

  @override
  State<LeavePage> createState() => _LeavePageState();
}

class _LeavePageState extends State<LeavePage> {
  LeaveData? _leaveData;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchLeaves();
  }

  Future<void> _fetchLeaves() async {
    setState(() {
      _loading = true;
      _error = null;
      _leaveData = null;
    });

    final data = await getLeaves(context, employeeId: widget.employeeId);

    if (!mounted) return;
    setState(() {
      _loading = false;
      if (data == null) {
        _error = 'leave not found'.tr;
      } else {
        _leaveData = data;
      }
    });
  }

  void _shareLeave() {
    if (_leaveData == null) return;
    final buffer = StringBuffer();
    buffer.writeln(_leaveData!.employee);
    buffer.writeln('');
    buffer.writeln('${'leave_balances'.tr}:');
    for (final b in _leaveData!.balances) {
      buffer.writeln('  ${b.type}: ${b.remainingDays}/${b.totalDays} ${'days_short'.tr}');
    }
    if (_leaveData!.history.isNotEmpty) {
      buffer.writeln('');
      buffer.writeln('${'leave_history'.tr}:');
      for (final r in _leaveData!.history) {
        buffer.writeln('  ${r.type}: ${_fmtDate(r.startDate)} — ${_fmtDate(r.endDate)} (${r.days} ${'days_short'.tr}) [${r.status}]');
      }
    }
    HapticFeedback.lightImpact();
    Share.share(buffer.toString());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: widget.onNavigate == null
          ? null
          : AppDrawer(onNavigate: widget.onNavigate, currentIndex: 3),
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
        title: BigText(content: 'leave_sick_days'.tr, fontWeight: FontWeight.bold),
        centerTitle: true,
        actions: [
          if (_leaveData != null)
            IconButton(
              icon: const Icon(Icons.share),
              tooltip: 'share'.tr,
              onPressed: _shareLeave,
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'refresh'.tr,
            onPressed: _loading ? null : _fetchLeaves,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _fetchLeaves,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.all(Dimensions.width20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_loading)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32.0),
                    child: CircularProgressIndicator(color: AppColors.mainColor),
                  ),
                ),
              if (_error != null)
                Center(
                  child: Padding(
                    padding: EdgeInsets.all(Dimensions.height30),
                    child: Column(
                      children: [
                        const Icon(Icons.wifi_off, size: 56, color: Colors.grey),
                        SizedBox(height: Dimensions.height30 / 2),
                        Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.grey, fontSize: 15),
                        ),
                        SizedBox(height: Dimensions.height30 / 2),
                        ElevatedButton.icon(
                          onPressed: _fetchLeaves,
                          icon: const Icon(Icons.refresh),
                          label: Text('refresh'.tr),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_leaveData != null) ...[
                GestureDetector(
                  onLongPress: () {
                    Clipboard.setData(ClipboardData(text: _leaveData!.employee));
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
                      child: Text(
                        _leaveData!.employee,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(height: Dimensions.height30 / 2),
                Builder(builder: (context) {
                  final now = DateTime.now();
                  final upcoming = _leaveData!.history.where((r) {
                    try {
                      return DateTime.parse(r.startDate).isAfter(now);
                    } catch (_) {
                      return false;
                    }
                  }).toList();
                  if (upcoming.isEmpty) return const SizedBox.shrink();
                  upcoming.sort((a, b) {
                    try {
                      return DateTime.parse(a.startDate).compareTo(DateTime.parse(b.startDate));
                    } catch (_) { return 0; }
                  });
                  final next = upcoming.first;
                  final daysUntil = DateTime.parse(next.startDate).difference(now).inDays;
                  return Column(
                    children: [
                      Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(Dimensions.width20),
                        decoration: BoxDecoration(
                          color: Colors.orange.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.orange.shade300),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.event_available, color: Colors.orange.shade700, size: 22),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'upcoming_leave'.tr,
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                      color: Colors.orange.shade800,
                                    ),
                                  ),
                                  Text(
                                    '${next.type}  •  ${_fmtDate(next.startDate)}',
                                    style: TextStyle(fontSize: 12, color: Colors.orange.shade700),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.orange.shade100,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '$daysUntil ${'days_short'.tr}',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.orange.shade800,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: Dimensions.height30 / 2),
                    ],
                  );
                }),
                Row(
                  children: [
                    BigText(content: 'leave_balances'.tr, fontWeight: FontWeight.bold),
                    const Spacer(),
                    if (_leaveData!.balances.isNotEmpty) ...[
                      _buildTotalChip(
                        _leaveData!.balances.fold(0, (s, b) => s + b.usedDays),
                        _leaveData!.balances.fold(0, (s, b) => s + b.totalDays),
                      ),
                    ],
                  ],
                ),
                SizedBox(height: Dimensions.height30 / 4),
                if (_leaveData!.balances.isEmpty)
                  Card(
                    child: Padding(
                      padding: EdgeInsets.all(Dimensions.width20),
                      child: Center(
                        child: Text(
                          'no_records'.tr,
                          style: const TextStyle(color: Colors.grey, fontSize: 13),
                        ),
                      ),
                    ),
                  )
                else
                  ..._leaveData!.balances.map((b) => _buildBalanceCard(b)),
                SizedBox(height: Dimensions.height30 / 2),
                Row(
                  children: [
                    BigText(content: 'leave_history'.tr, fontWeight: FontWeight.bold),
                    if (_leaveData!.history.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.mainColor.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${_leaveData!.history.length}',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: AppColors.mainColor,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                SizedBox(height: Dimensions.height30 / 4),
                if (_leaveData!.history.isEmpty)
                  Card(
                    child: Padding(
                      padding: EdgeInsets.all(Dimensions.width20),
                      child: Center(
                        child: Text(
                          'no_records'.tr,
                          style: const TextStyle(color: Colors.grey, fontSize: 13),
                        ),
                      ),
                    ),
                  )
                else
                  ...() {
                    final sorted = [..._leaveData!.history]
                      ..sort((a, b) {
                        try {
                          return DateTime.parse(b.startDate).compareTo(DateTime.parse(a.startDate));
                        } catch (_) {
                          return 0;
                        }
                      });
                    final widgets = <Widget>[];
                    int? lastYear;
                    for (final r in sorted) {
                      int? year;
                      try { year = DateTime.parse(r.startDate).year; } catch (_) {}
                      if (year != null && year != lastYear) {
                        lastYear = year;
                        widgets.add(Padding(
                          padding: const EdgeInsets.only(top: 8, bottom: 4, left: 4),
                          child: Text(
                            '$year',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Colors.grey.shade500,
                              letterSpacing: 1.2,
                            ),
                          ),
                        ));
                      }
                      widgets.add(_buildHistoryCard(r));
                    }
                    return widgets;
                  }(),
                SizedBox(height: Dimensions.height30),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTotalChip(int used, int total) {
    final remaining = total - used;
    final color = remaining > 0 ? AppColors.mainColor : AppColors.niceRed;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Text(
        '$remaining / $total ${'days_short'.tr}',
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color),
      ),
    );
  }

  Widget _buildBalanceCard(LeaveBalance balance) {
    final progress = balance.totalDays > 0 ? balance.usedDays / balance.totalDays : 0.0;
    final isExhausted = balance.remainingDays <= 0;
    final isLow = balance.remainingDays > 0 && balance.remainingDays <= 3;
    final color = isExhausted ? AppColors.niceRed : AppColors.mainColor;

    return GestureDetector(
      onLongPress: () {
        Clipboard.setData(ClipboardData(
          text: '${balance.type}: ${balance.remainingDays}/${balance.totalDays} ${'days_short'.tr}',
        ));
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('copied'.tr),
          duration: const Duration(seconds: 1),
          behavior: SnackBarBehavior.floating,
        ));
      },
      child: Card(
      child: Padding(
        padding: EdgeInsets.all(Dimensions.width20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    balance.type,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                ),
                if (isLow)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade700.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.orange.shade700.withOpacity(0.4)),
                    ),
                    child: Text(
                      '${balance.remainingDays} ${'days_short'.tr}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Colors.orange.shade800,
                      ),
                    ),
                  )
                else if (isExhausted)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.niceRed.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '0 ${'days_short'.tr}',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: AppColors.niceRed,
                      ),
                    ),
                  ),
              ],
            ),
            SizedBox(height: Dimensions.height30 / 3),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 8,
                backgroundColor: Colors.grey.shade200,
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
            SizedBox(height: Dimensions.height30 / 3),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('${'used_days'.tr}: ${balance.usedDays}',
                    style: const TextStyle(fontSize: 13, color: Colors.black54)),
                Text(
                  '${'remaining_days'.tr}: ${balance.remainingDays}',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color),
                ),
              ],
            ),
            SizedBox(height: Dimensions.height30 / 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('${'total_days'.tr}: ${balance.totalDays}',
                    style: const TextStyle(fontSize: 12, color: Colors.black38)),
                if (balance.totalDays > 0)
                  Text(
                    '${(progress * 100).toStringAsFixed(0)}% ${'used_days'.tr.toLowerCase()}',
                    style: TextStyle(fontSize: 11, color: color.withOpacity(0.6)),
                  ),
              ],
            ),
          ],
        ),
      ),
      ),
    );
  }

  Widget _buildHistoryCard(LeaveRecord record) {
    final lower = record.type.toLowerCase();
    final isSick = lower.contains('больн') || lower.contains('ауру') || lower.contains('sick');
    final isMaternity = lower.contains('декрет') || lower.contains('бала');
    final isStudy = lower.contains('учеб') || lower.contains('оқу');
    final isUnpaid = lower.contains('содерж') || lower.contains('жалақы') || lower.contains('ақы');

    final icon = isSick
        ? Icons.local_hospital
        : isMaternity
            ? Icons.family_restroom
            : isStudy
                ? Icons.school_outlined
                : isUnpaid
                    ? Icons.work_off_outlined
                    : Icons.beach_access;
    final iconColor = isSick ? AppColors.niceRed : AppColors.mainColor;

    final isApproved = record.status.toLowerCase().contains('утвержд') ||
        record.status.toLowerCase().contains('бекіт') ||
        record.status.toLowerCase().contains('закр') ||
        record.status.toLowerCase().contains('жабы');
    final statusColor = isApproved ? AppColors.mainColor : Colors.orange.shade800;
    final statusBg = isApproved
        ? AppColors.mainColor.withOpacity(0.12)
        : Colors.orange.withOpacity(0.12);

    return Card(
      child: ListTile(
        leading: Icon(icon, color: iconColor, size: 28),
        title: Text(record.type, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        subtitle: Text(
          '${_fmtDate(record.startDate)} — ${_fmtDate(record.endDate)}  (${record.days} ${'days_short'.tr})',
          style: const TextStyle(fontSize: 13),
        ),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: statusBg,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isApproved ? Icons.check_circle_outline : Icons.access_time_outlined,
                size: 12,
                color: statusColor,
              ),
              const SizedBox(width: 3),
              Text(
                record.status,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: statusColor),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _fmtDate(String raw) {
    try {
      final d = DateTime.parse(raw);
      return '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
    } catch (_) {
      return raw;
    }
  }
}
