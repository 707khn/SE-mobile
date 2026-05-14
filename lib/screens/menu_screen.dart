import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/menu_request.dart';
import '../utils/colors.dart';
import '../utils/dimensions.dart';
import '../widgets/custom_text.dart';

class MenuScreen extends StatefulWidget {
  const MenuScreen({Key? key}) : super(key: key);

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

  void _changeDate(int days) {
    setState(() => _selectedDate = _selectedDate.add(Duration(days: days)));
    _loadMenu();
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

  String get _dateLabel {
    if (_isToday) return 'today'.tr;
    return DateFormat('d MMMM yyyy', Get.locale?.languageCode == 'KZ' ? 'ru' : 'ru').format(_selectedDate);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        backgroundColor: AppColors.mainColor,
        foregroundColor: Colors.white,
        elevation: 0,
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
        ],
      ),
      body: RefreshIndicator(
        color: AppColors.mainColor,
        onRefresh: _loadMenu,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _buildDateNavigation()),
            if (_loading)
              const SliverFillRemaining(
                child: Center(child: CircularProgressIndicator(color: AppColors.mainColor)),
              )
            else if (_error)
              SliverFillRemaining(child: _buildError())
            else if (_items.isEmpty)
              SliverFillRemaining(child: _buildEmpty())
            else
              _buildMenuList(),
          ],
        ),
      ),
    );
  }

  Widget _buildDateNavigation() {
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
            _dateLabel,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right, color: Colors.white, size: 32),
            onPressed: () => _changeDate(1),
          ),
        ],
      ),
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
      child: Text(
        category,
        style: TextStyle(
          color: AppColors.mainColor,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildItemTile(Map<String, dynamic> item) {
    final name = item['name'] as String? ?? '—';
    final price = item['price'];
    final priceStr = price != null
        ? NumberFormat('#,##0', 'ru').format(price) + ' ₸'
        : '';

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
            if (priceStr.isNotEmpty) ...[
              const SizedBox(width: 12),
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
