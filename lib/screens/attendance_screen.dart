import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/attendance_request.dart';
import '../utils/colors.dart';
import '../utils/dimensions.dart';
import '../widgets/custom_text.dart';

class AttendanceScreen extends StatefulWidget {
  const AttendanceScreen({Key? key}) : super(key: key);

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  DateTime _selectedDate = DateTime.now();
  bool _loading = false;
  bool _error = false;
  List<_EmployeeDay> _rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    final dateStr = DateFormat('yyyy-MM-dd').format(_selectedDate);
    final result = await getAttendanceForDate(dateStr);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (result['message'] == 'Success') {
        _rows = _parseEvents(result['events'] as List<dynamic>);
      } else {
        _error = true;
        _rows = [];
      }
    });
  }

  List<_EmployeeDay> _parseEvents(List<dynamic> events) {
    final map = <String, _EmployeeDay>{};
    for (final e in events) {
      final id = e['employee_id'] as String;
      final name = e['full_name'] as String? ?? id;
      final dir = e['direction'] as String;
      final ts = e['timestamp'] as String;
      final time = ts.length >= 16 ? ts.substring(11, 16) : ts;

      final row = map.putIfAbsent(id, () => _EmployeeDay(id: id, name: name));
      if (dir == 'in' && row.firstIn == null) row.firstIn = time;
      if (dir == 'out') row.lastOut = time;
      row.eventCount++;
    }
    final list = map.values.toList();
    list.sort((a, b) => (a.firstIn ?? '99:99').compareTo(b.firstIn ?? '99:99'));
    return list;
  }

  bool get _isToday {
    final now = DateTime.now();
    return _selectedDate.year == now.year &&
        _selectedDate.month == now.month &&
        _selectedDate.day == now.day;
  }

  void _changeDate(int delta) {
    setState(() => _selectedDate = _selectedDate.add(Duration(days: delta)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        backgroundColor: AppColors.mainColor,
        foregroundColor: Colors.white,
        elevation: 0,
        title: BigText(content: 'attendance'.tr, color: Colors.white),
        actions: [
          if (!_isToday)
            IconButton(
              icon: const Icon(Icons.today),
              tooltip: 'today'.tr,
              onPressed: () {
                setState(() => _selectedDate = DateTime.now());
                _load();
              },
            ),
        ],
      ),
      body: RefreshIndicator(
        color: AppColors.mainColor,
        onRefresh: _load,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _buildDateNav()),
            if (_loading)
              const SliverFillRemaining(
                child: Center(
                    child: CircularProgressIndicator(color: AppColors.mainColor)),
              )
            else if (_error)
              SliverFillRemaining(child: _buildError())
            else if (_rows.isEmpty)
              SliverFillRemaining(child: _buildEmpty())
            else
              _buildList(),
          ],
        ),
      ),
    );
  }

  Widget _buildDateNav() {
    final locale =
        Get.locale?.languageCode == 'KZ' ? 'ru' : 'ru';
    final label = _isToday
        ? 'today'.tr
        : DateFormat('d MMMM yyyy', locale).format(_selectedDate);
    return Container(
      color: AppColors.mainColor,
      padding: EdgeInsets.only(
        left: Dimensions.width20,
        right: Dimensions.width20,
        bottom: Dimensions.height30 * 0.6,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left, color: Colors.white, size: 32),
            onPressed: () => _changeDate(-1),
          ),
          Text(
            label,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right, color: Colors.white, size: 32),
            onPressed: () => _changeDate(1),
          ),
        ],
      ),
    );
  }

  SliverList _buildList() {
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          if (index == 0) return _buildSummaryBar();
          final row = _rows[index - 1];
          return _buildRow(row);
        },
        childCount: _rows.length + 1,
      ),
    );
  }

  Widget _buildSummaryBar() {
    return Container(
      margin: EdgeInsets.all(Dimensions.width20),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.mainColor.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.people, color: AppColors.mainColor, size: 20),
          const SizedBox(width: 8),
          Text(
            '${_rows.length}',
            style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: AppColors.mainColor),
          ),
          const SizedBox(width: 4),
          Text(
            'records_count'.tr,
            style: TextStyle(fontSize: 14, color: Colors.grey[700]),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(_EmployeeDay row) {
    return Container(
      margin: EdgeInsets.symmetric(
          horizontal: Dimensions.width20, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 4,
              offset: const Offset(0, 2))
        ],
      ),
      child: Padding(
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: AppColors.mainColor.withOpacity(0.15),
              child: Text(
                _initials(row.name),
                style: const TextStyle(
                    color: AppColors.mainColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 14),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(row.name,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      if (row.firstIn != null) ...[
                        const Icon(Icons.login,
                            size: 13, color: Colors.green),
                        const SizedBox(width: 3),
                        Text(row.firstIn!,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.green)),
                        const SizedBox(width: 12),
                      ],
                      if (row.lastOut != null) ...[
                        const Icon(Icons.logout,
                            size: 13, color: Colors.redAccent),
                        const SizedBox(width: 3),
                        Text(row.lastOut!,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.redAccent)),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            Text(
              '${row.eventCount}',
              style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey[500]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.people_outline, size: 72, color: Colors.grey[300]),
          SizedBox(height: Dimensions.height30 / 2),
          BigText(content: 'no_attendance_data'.tr, color: Colors.grey),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.wifi_off, size: 64, color: Colors.grey[400]),
          SizedBox(height: Dimensions.height30 / 2),
          BigText(content: 'connection_error'.tr, color: Colors.grey),
          SizedBox(height: Dimensions.height30 / 2),
          TextButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            label: Text('refresh'.tr),
            style: TextButton.styleFrom(
                foregroundColor: AppColors.mainColor),
          ),
        ],
      ),
    );
  }

  String _initials(String name) {
    final parts = name.trim().split(' ');
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }
}

class _EmployeeDay {
  final String id;
  final String name;
  String? firstIn;
  String? lastOut;
  int eventCount = 0;

  _EmployeeDay({required this.id, required this.name});
}
