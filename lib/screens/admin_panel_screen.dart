import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../requests/admin_request.dart';
import '../utils/colors.dart';
import '../utils/dimensions.dart';
import '../widgets/app_drawer.dart';
import '../widgets/custom_text.dart';
import 'admin_employee_screen.dart';

/// Staff directory for the system administrator: search anyone, open their
/// turnstile report, payslips and leave.
class AdminPanelScreen extends StatefulWidget {
  const AdminPanelScreen({Key? key}) : super(key: key);

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen> {
  final _searchController = TextEditingController();

  List<AdminEmployee> _all = [];
  bool _loading = true;
  bool _error = false;
  String _query = '';
  String? _department; // null = all departments
  bool _onlyWithLogin = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final rows = await fetchAllEmployees();
      if (!mounted) return;
      setState(() {
        _all = rows;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = true;
      });
    }
  }

  List<String> get _departments {
    final names = _all
        .map((e) => e.department)
        .where((d) => d.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return names;
  }

  List<AdminEmployee> get _filtered {
    final q = _query.trim().toLowerCase();
    return _all.where((e) {
      if (_onlyWithLogin && !e.hasLogin) return false;
      if (_department != null && e.department != _department) return false;
      if (q.isEmpty) return true;
      return e.fullName.toLowerCase().contains(q) ||
          e.jobTitle.toLowerCase().contains(q) ||
          e.employeeId.toLowerCase().contains(q) ||
          e.login.toLowerCase().contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final list = _filtered;
    return Scaffold(
      backgroundColor: Colors.grey[50],
      drawer: const AppDrawer(),
      appBar: AppBar(
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu),
            tooltip: MaterialLocalizations.of(context).openAppDrawerTooltip,
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
        title: BigText(content: 'admin_panel'.tr, color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'refresh'.tr,
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: Column(
        children: [
          _buildSearchBar(),
          if (!_loading && !_error) _buildFilters(),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.mainColor))
                : _error
                    ? _buildError()
                    : list.isEmpty
                        ? _buildEmpty()
                        : RefreshIndicator(
                            color: AppColors.mainColor,
                            onRefresh: _load,
                            child: ListView.builder(
                              itemCount: list.length,
                              itemBuilder: (_, i) => _buildTile(list[i]),
                            ),
                          ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      color: AppColors.mainColor,
      padding: EdgeInsets.fromLTRB(
          Dimensions.width20, 0, Dimensions.width20, Dimensions.height30 * 0.4),
      child: TextField(
        controller: _searchController,
        onChanged: (v) => setState(() => _query = v),
        decoration: InputDecoration(
          hintText: 'admin_search_hint'.tr,
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _query = '');
                  },
                ),
          filled: true,
          fillColor: Colors.white,
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  Widget _buildFilters() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: Dimensions.width20),
              children: [
                _chip(
                  label: 'admin_all_departments'.tr,
                  selected: _department == null,
                  onTap: () => setState(() => _department = null),
                ),
                ..._departments.map((d) => _chip(
                      label: d,
                      selected: _department == d,
                      onTap: () => setState(() => _department = d),
                    )),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.only(left: Dimensions.width20, right: 8, top: 4),
            child: Row(
              children: [
                Text(
                  '${'admin_found'.tr}: ${_filtered.length}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
                const Spacer(),
                Text('admin_only_with_login'.tr,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
                Switch(
                  value: _onlyWithLogin,
                  activeColor: AppColors.mainColor,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (v) => setState(() => _onlyWithLogin = v),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        selected: selected,
        selectedColor: AppColors.mainColor.withOpacity(0.18),
        onSelected: (_) => onTap(),
      ),
    );
  }

  Widget _buildTile(AdminEmployee e) {
    final initials = e.fullName.trim().isEmpty
        ? '?'
        : e.fullName.trim().split(RegExp(r'\s+')).take(2).map((w) => w[0]).join();
    return Container(
      margin: EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: e.hasLogin
              ? AppColors.mainColor.withOpacity(0.15)
              : Colors.grey.shade200,
          child: Text(
            initials.toUpperCase(),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: e.hasLogin ? AppColors.mainColor : Colors.grey.shade600,
            ),
          ),
        ),
        title: Text(e.fullName, style: const TextStyle(fontSize: 14)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(e.jobTitle,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
            const SizedBox(height: 2),
            Wrap(
              spacing: 6,
              runSpacing: 2,
              children: [
                if (e.hasLogin)
                  _badge('${'login'.tr}: ${e.login}', AppColors.mainColor),
                if (e.payslipCount > 0)
                  _badge('${'payslip'.tr}: ${e.payslipCount}',
                      Colors.blue.shade700),
                if (e.accessCount > 0)
                  _badge('${'tab_turnstile'.tr}: ${e.accessCount}',
                      Colors.orange.shade800),
              ],
            ),
          ],
        ),
        isThreeLine: true,
        trailing: const Icon(Icons.chevron_right, size: 20),
        onTap: () => Get.to(() => AdminEmployeeScreen(employee: e)),
      ),
    );
  }

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 10, fontWeight: FontWeight.w600, color: color)),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search_off, size: 60, color: Colors.grey.shade300),
          SizedBox(height: Dimensions.height30 / 2),
          Text('no_records'.tr,
              style: const TextStyle(color: Colors.grey, fontSize: 15)),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.wifi_off, size: 60, color: Colors.grey.shade400),
          SizedBox(height: Dimensions.height30 / 2),
          Text('load_error'.tr,
              style: const TextStyle(color: Colors.grey, fontSize: 15)),
          SizedBox(height: Dimensions.height30 / 2),
          TextButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            label: Text('refresh'.tr),
            style: TextButton.styleFrom(foregroundColor: AppColors.mainColor),
          ),
        ],
      ),
    );
  }
}
