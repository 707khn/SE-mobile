import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/attendance_request.dart';
import '../utils/colors.dart';
import '../utils/dimensions.dart';
import '../utils/initials.dart';
import '../widgets/app_drawer.dart';
import '../widgets/custom_text.dart';
import '../widgets/day_navigator.dart';
import '../utils/app_theme.dart';
import '../utils/load_problem.dart';
import '../widgets/load_error_view.dart';
import 'on_site_screen.dart';

class AttendanceScreen extends StatefulWidget {
  const AttendanceScreen({Key? key}) : super(key: key);

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  DateTime _selectedDate = DateTime.now();
  bool _loading = false;
  bool _error = false;
  LoadProblem? _problem;
  List<_EmployeeDay> _rows = [];

  /// Номер последней загрузки: стрелки работают и пока день грузится, и
  /// ответ за прежний день, пришедший позже, иначе лёг бы под новую дату.
  int _loadSeq = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final seq = ++_loadSeq;
    setState(() {
      _loading = true;
      _error = false;
    });
    final dateStr = DateFormat('yyyy-MM-dd').format(_selectedDate);
    final result = await getAttendanceForDate(dateStr);
    if (!mounted || seq != _loadSeq) return;
    setState(() {
      _loading = false;
      if (result['message'] == 'Success') {
        _rows = _parseEvents(result['events'] as List<dynamic>);
      } else {
        _error = true;
        _problem = problemIn(result);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.pageColor,
      drawer: const AppDrawer(),
      appBar: AppBar(
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu),
            tooltip: MaterialLocalizations.of(context).openAppDrawerTooltip,
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
        title: BigText(content: 'attendance'.tr, color: Colors.white),
        actions: [
          IconButton(
            key: const Key('attendance_now'),
            icon: const Icon(Icons.how_to_reg_outlined),
            tooltip: 'onsite_title'.tr,
            onPressed: () => Get.to(() => const OnSiteScreen()),
          ),
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
        color: context.accentColor,
        onRefresh: _load,
        child: DaySwipeDetector(
          date: _selectedDate,
          enabled: !_loading,
          onChanged: (d) {
            setState(() => _selectedDate = d);
            _load();
          },
          child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _buildDateNav()),
            if (_loading)
              SliverFillRemaining(
                child: Center(
                    child: CircularProgressIndicator(color: context.accentColor)),
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
      ),
    );
  }

  Widget _buildDateNav() {
    return DayNavigator(
      date: _selectedDate,
      onChanged: (d) {
        setState(() => _selectedDate = d);
        _load();
      },
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
          Icon(Icons.people, color: context.accentColor, size: 20),
          const SizedBox(width: 8),
          Text(
            '${_rows.length}',
            style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: context.accentColor),
          ),
          const SizedBox(width: 4),
          Text(
            'records_count'.tr,
            style: TextStyle(fontSize: 13, color: context.mutedColor),
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
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: context.cardShadow,
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
                initialsOf(row.name),
                style: TextStyle(
                    color: context.accentColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 13),
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
                  color: context.mutedColor),
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
          Icon(Icons.people_outline, size: 72, color: context.hairlineColor),
          SizedBox(height: Dimensions.height30 / 2),
          BigText(content: 'no_attendance_data'.tr, color: context.mutedColor),
        ],
      ),
    );
  }

  Widget _buildError() => LoadErrorView(problem: _problem, onRetry: _load);
}

class _EmployeeDay {
  final String id;
  final String name;
  String? firstIn;
  String? lastOut;
  int eventCount = 0;

  _EmployeeDay({required this.id, required this.name});
}
