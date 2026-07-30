import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/menu_request.dart';
import '../utils/colors.dart';
import '../utils/dimensions.dart';
import '../widgets/custom_text.dart';
import '../widgets/day_navigator.dart';

/// Canteen menu editor, available to the canteen technologist.
///
/// The backend replaces a day's menu wholesale on save, so the screen keeps the
/// full day in memory and posts all of it at once.
class MenuEditScreen extends StatefulWidget {
  const MenuEditScreen({Key? key, required this.initialDate}) : super(key: key);

  final DateTime initialDate;

  @override
  State<MenuEditScreen> createState() => _MenuEditScreenState();
}

class _MenuEditScreenState extends State<MenuEditScreen> {
  /// Suggested sections; the technologist can still type any other name.
  /// Localised, since the chosen label is what gets stored and displayed.
  static const _categoryKeys = [
    'menu_category_salad',
    'menu_category_first',
    'menu_category_second',
    'menu_category_garnish',
    'menu_category_bakery',
    'menu_category_drink',
  ];

  List<String> get _suggestedCategories =>
      _categoryKeys.map((k) => k.tr).toList();

  late DateTime _date;
  final List<_MenuEntry> _items = [];
  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _date = widget.initialDate;
    _load();
  }

  String get _dateKey => DateFormat('yyyy-MM-dd').format(_date);

  Future<void> _load() async {
    setState(() => _loading = true);
    final result = await getMenuForDate(_dateKey);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _dirty = false;
      _items
        ..clear()
        ..addAll(((result['items'] as List<dynamic>?) ?? []).map((raw) {
          final item = raw as Map<String, dynamic>;
          return _MenuEntry(
            category: (item['category'] as String?) ?? '',
            name: (item['name'] as String?) ?? '',
            price: (item['price'] as num?)?.toDouble(),
          );
        }));
    });
  }

  /// Asks before throwing away edits; returns true when it is safe to continue.
  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('menu_unsaved_title'.tr),
        content: Text('menu_unsaved_body'.tr),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('cancel'.tr),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('menu_discard'.tr,
                style: TextStyle(color: Colors.red.shade700)),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final payload = _items
        .where((e) => e.name.trim().isNotEmpty && e.category.trim().isNotEmpty)
        .map((e) => {
              'category': e.category.trim(),
              'name': e.name.trim(),
              'price': e.price,
            })
        .toList();
    final ok = await saveMenuForDate(_dateKey, payload);
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (ok) _dirty = false;
    });
    HapticFeedback.lightImpact();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? 'menu_saved'.tr : 'menu_save_failed'.tr),
      backgroundColor: ok ? AppColors.mainColor : Colors.red.shade700,
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _editItem({_MenuEntry? existing}) async {
    final nameController = TextEditingController(text: existing?.name ?? '');
    final priceController = TextEditingController(
        text: existing?.price != null ? existing!.price!.toStringAsFixed(0) : '');
    // Default to the section the technologist last used — most dishes are
    // entered section by section.
    var category = existing?.category ??
        (_items.isNotEmpty ? _items.last.category : _suggestedCategories.first);
    final categoryController = TextEditingController(text: category);

    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(existing == null ? 'add_item'.tr : 'menu_edit_dish'.tr),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('menu_category'.tr,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  children: _suggestedCategories.map((c) {
                    final selected = categoryController.text.trim() == c;
                    return ChoiceChip(
                      label: Text(c),
                      selected: selected,
                      onSelected: (_) =>
                          setDialogState(() => categoryController.text = c),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: categoryController,
                  decoration: InputDecoration(
                    labelText: 'menu_category'.tr,
                    isDense: true,
                  ),
                  onChanged: (_) => setDialogState(() {}),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: nameController,
                  autofocus: existing == null,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: 'menu_item_name'.tr,
                    hintText: 'menu_dish_hint'.tr,
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: priceController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'menu_price'.tr,
                    isDense: true,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            if (existing != null)
              TextButton.icon(
                onPressed: () => Navigator.pop(ctx, 'delete'),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: Text('remove_item'.tr),
                style: TextButton.styleFrom(foregroundColor: Colors.red.shade700),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              child: Text('cancel'.tr),
            ),
            ElevatedButton(
              onPressed: () {
                if (nameController.text.trim().isEmpty ||
                    categoryController.text.trim().isEmpty) {
                  return;
                }
                Navigator.pop(ctx, 'save');
              },
              child: Text('menu_save'.tr),
            ),
          ],
        ),
      ),
    );

    if (action == 'delete' && existing != null) {
      _removeItem(existing);
      return;
    }
    if (action != 'save') return;
    category = categoryController.text.trim();
    final name = nameController.text.trim();
    final price = double.tryParse(priceController.text.trim().replaceAll(',', '.'));

    setState(() {
      _dirty = true;
      if (existing == null) {
        _items.add(_MenuEntry(category: category, name: name, price: price));
      } else {
        existing
          ..category = category
          ..name = name
          ..price = price;
      }
    });
  }

  void _removeItem(_MenuEntry item) {
    final index = _items.indexOf(item);
    if (index < 0) return;
    setState(() {
      _items.removeAt(index);
      _dirty = true;
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('${'menu_dish_removed'.tr}: ${item.name}'),
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(
          label: 'undo'.tr,
          // Put it back where it was, so the section order is preserved.
          onPressed: () => setState(
              () => _items.insert(index.clamp(0, _items.length), item)),
        ),
      ));
  }

  Map<String, List<_MenuEntry>> get _grouped {
    final map = <String, List<_MenuEntry>>{};
    for (final item in _items) {
      map.putIfAbsent(item.category, () => []).add(item);
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        if (await _confirmDiscard() && mounted) Navigator.pop(context);
      },
      child: Scaffold(
        backgroundColor: Colors.grey[50],
        appBar: AppBar(
          title: BigText(content: 'menu_edit_title'.tr, color: Colors.white),
          actions: [
            if (_saving)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 18),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  ),
                ),
              )
            else
              IconButton(
                icon: const Icon(Icons.check),
                tooltip: 'menu_save'.tr,
                onPressed: _dirty ? _save : null,
              ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _editItem(),
          icon: const Icon(Icons.add),
          label: Text('add_item'.tr),
        ),
        body: Column(
          children: [
            _buildDateBar(),
            if (_dirty)
              Container(
                width: double.infinity,
                color: Colors.orange.shade50,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    Icon(Icons.edit_note, size: 18, color: Colors.orange.shade800),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('menu_unsaved_hint'.tr,
                          style: TextStyle(
                              fontSize: 12, color: Colors.orange.shade900)),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(color: AppColors.mainColor))
                  : _items.isEmpty
                      ? _buildEmpty()
                      : _buildList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDateBar() {
    return DayNavigator(
      date: _date,
      onChanged: (d) async {
        if (!await _confirmDiscard()) return;
        setState(() => _date = d);
        _load();
      },
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.ramen_dining, size: 68, color: Colors.grey[300]),
          SizedBox(height: Dimensions.height30 / 2),
          Text('menu_empty_editor'.tr,
              style: const TextStyle(color: Colors.grey, fontSize: 15)),
        ],
      ),
    );
  }

  Widget _buildList() {
    final grouped = _grouped;
    final tiles = <Widget>[];

    grouped.forEach((category, items) {
      tiles.add(Padding(
        padding: EdgeInsets.fromLTRB(
            Dimensions.width20, Dimensions.height30 * 0.5, Dimensions.width20, 4),
        child: Text(
          category,
          style: TextStyle(
            color: AppColors.mainColor,
            fontSize: 13,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
          ),
        ),
      ));
      tiles.addAll(items.map(_buildItemTile));
    });

    tiles.add(const SizedBox(height: 88));
    return ListView(children: tiles);
  }

  Widget _buildItemTile(_MenuEntry item) {
    return Dismissible(
      key: ObjectKey(item),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        margin: EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 4),
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: Colors.red.shade600,
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      onDismissed: (_) => _removeItem(item),
      child: Container(
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
          title: Text(item.name, style: const TextStyle(fontSize: 15)),
          subtitle: item.price != null
              ? Text('${NumberFormat('#,##0', 'ru').format(item.price)} ₸',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.mainColor))
              : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: Icon(Icons.edit_outlined,
                    size: 20, color: Colors.grey.shade600),
                tooltip: 'menu_edit_dish'.tr,
                onPressed: () => _editItem(existing: item),
              ),
              IconButton(
                icon: Icon(Icons.delete_outline,
                    size: 20, color: Colors.red.shade400),
                tooltip: 'remove_item'.tr,
                onPressed: () => _removeItem(item),
              ),
            ],
          ),
          onTap: () => _editItem(existing: item),
        ),
      ),
    );
  }
}

class _MenuEntry {
  _MenuEntry({required this.category, required this.name, this.price});

  String category;
  String name;
  double? price;
}
