import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/menu_request.dart';
import '../utils/colors.dart';
import '../utils/dimensions.dart';
import '../utils/role_helper.dart';
import '../widgets/app_drawer.dart';
import '../widgets/custom_text.dart';
import '../widgets/day_navigator.dart';
import '../widgets/skeleton.dart';
import 'menu_edit_screen.dart';

class MenuScreen extends StatefulWidget {
  const MenuScreen({Key? key, this.onNavigate, this.job = ''}) : super(key: key);

  /// Supplied inside the bottom-nav shell: enables the shared drawer and
  /// lets it switch tab. Null on drill-down views, which keep a back arrow.
  final ValueChanged<int>? onNavigate;

  /// Job title of the signed-in user; decides who sees the edit button.
  final String job;

  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> {
  DateTime _selectedDate = DateTime.now();
  bool _loading = false;
  bool _error = false;
  List<dynamic> _items = [];

  @override
  void initState() {
    super.initState();
    _loadMenu();
  }

  Future<void> _loadMenu() async {
    setState(() { _loading = true; _error = false; });
    final dateStr = DateFormat('yyyy-MM-dd').format(_selectedDate);
    final result = await getMenuForDate(dateStr);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (result['message'] == 'Success') {
        _items = result['items'] as List<dynamic>;
      } else {
        _items = [];
        _error = result['items'] == null;
      }
    });
  }

  Map<String, List<Map<String, dynamic>>> _groupByCategory() {
    final map = <String, List<Map<String, dynamic>>>{};
    for (final item in _items) {
      final cat = (item['category'] as String?) ?? '—';
      map.putIfAbsent(cat, () => []).add(item as Map<String, dynamic>);
    }
    return map;
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
      backgroundColor: Colors.grey[50],
      drawer: widget.onNavigate == null
          ? null
          : AppDrawer(onNavigate: widget.onNavigate, currentIndex: 4),
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
        title: BigText(content: 'canteen_menu'.tr, color: Colors.white),
        actions: [
          if (!_isToday)
            IconButton(
              icon: const Icon(Icons.today),
              tooltip: 'today'.tr,
              onPressed: () {
                setState(() => _selectedDate = DateTime.now());
                _loadMenu();
              },
            ),
          if (canEditMenu(widget.job))
            IconButton(
              icon: const Icon(Icons.edit_calendar),
              tooltip: 'menu_edit_title'.tr,
              onPressed: () async {
                await Get.to(() => MenuEditScreen(initialDate: _selectedDate));
                _loadMenu();
              },
            ),
        ],
      ),
      body: RefreshIndicator(
        color: AppColors.mainColor,
        onRefresh: _loadMenu,
        child: DaySwipeDetector(
          date: _selectedDate,
          enabled: !_loading,
          onChanged: (d) {
            setState(() => _selectedDate = d);
            _loadMenu();
          },
          child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _buildDateNavigation()),
            if (_loading)
              const SliverToBoxAdapter(child: SkeletonList(rows: 5))
            else if (_error)
              SliverFillRemaining(child: _buildError())
            else if (_items.isEmpty)
              SliverFillRemaining(child: _buildEmpty())
            else
              _buildMenuList(),
          ],
          ),
        ),
      ),
    );
  }

  Widget _buildDateNavigation() {
    return DayNavigator(
      date: _selectedDate,
      onChanged: (d) {
        setState(() => _selectedDate = d);
        _loadMenu();
      },
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.restaurant, size: 72, color: Colors.grey[300]),
          SizedBox(height: Dimensions.height30 / 2),
          BigText(content: 'no_menu_today'.tr, color: Colors.grey),
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
            onPressed: _loadMenu,
            icon: const Icon(Icons.refresh),
            label: Text('refresh'.tr),
            style: TextButton.styleFrom(foregroundColor: AppColors.mainColor),
          ),
        ],
      ),
    );
  }

  SliverList _buildMenuList() {
    final grouped = _groupByCategory();
    final categories = grouped.keys.toList();
    final tiles = <Widget>[];

    for (final cat in categories) {
      tiles.add(_buildCategoryHeader(cat));
      for (final item in grouped[cat]!) {
        tiles.add(_buildItemTile(item));
      }
    }

    tiles.add(SizedBox(height: Dimensions.height30));

    return SliverList(
      delegate: SliverChildListDelegate(tiles),
    );
  }

  Widget _buildCategoryHeader(String category) {
    return Container(
      margin: EdgeInsets.only(
        top: Dimensions.height30 * 0.6,
        left: Dimensions.width20,
        right: Dimensions.width20,
        bottom: 4,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              category,
              style: TextStyle(
                color: AppColors.mainColor,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
          ),
          // Names the right-hand column, so a bare "100 г" is not a mystery.
          if (_hasPortions)
            SizedBox(
              width: 62 + 16,
              child: Text(
                'menu_portion'.tr,
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
              ),
            ),
        ],
      ),
    );
  }

  /// True when at least one dish of the day carries a portion — the header
  /// label is pointless otherwise.
  bool get _hasPortions => _items.any((item) =>
      ((item as Map<String, dynamic>)['portion'] as String?)?.trim().isNotEmpty ??
      false);

  Widget _buildItemTile(Map<String, dynamic> item) {
    final name = item['name'] as String? ?? '—';
    final price = item['price'];
    final priceStr = price != null
        ? NumberFormat('#,##0', 'ru').format(price) + ' ₸'
        : '';
    // Unit is unknown — grams for food, millilitres for drinks — so the number
    // is shown as the export wrote it, with a neutral suffix.
    final portionRaw = (item['portion'] as String?)?.trim() ?? '';
    final portionStr = portionRaw.isEmpty
        ? ''
        : (RegExp(r'^[\d.,]+$').hasMatch(portionRaw)
            ? '$portionRaw ${'menu_portion_unit'.tr}'
            : portionRaw);

    return Container(
      margin: EdgeInsets.symmetric(
        horizontal: Dimensions.width20,
        vertical: 4,
      ),
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
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Text(name, style: const TextStyle(fontSize: 15)),
            ),
            // Portion in its own right-hand column, as in the source table.
            // Fixed width so the numbers line up down the list.
            if (portionStr.isNotEmpty) ...[
              const SizedBox(width: 10),
              SizedBox(
                width: 62,
                child: Text(
                  portionStr,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
            if (priceStr.isNotEmpty) ...[
              const SizedBox(width: 10),
              Text(
                priceStr,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.mainColor,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
