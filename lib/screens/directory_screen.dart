import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../requests/directory_request.dart';
import '../utils/app_theme.dart';
import '../utils/dimensions.dart';
import '../utils/offline_cache.dart';
import '../utils/open_external.dart';
import '../utils/search_fold.dart';
import '../widgets/app_drawer.dart';
import '../widgets/offline_notice.dart';
import '../widgets/custom_text.dart';
import '../utils/load_problem.dart';
import '../widgets/load_error_view.dart';

/// Телефонный справочник предприятия.
///
/// Справочник грузится целиком и дальше живёт в памяти: поиск идёт по уже
/// полученному списку, поэтому набор строки не дёргает сервер и работает,
/// когда связь пропала после открытия.
class DirectoryScreen extends StatefulWidget {
  const DirectoryScreen({Key? key}) : super(key: key);

  @override
  State<DirectoryScreen> createState() => _DirectoryScreenState();
}

class _DirectoryScreenState extends State<DirectoryScreen> {
  final TextEditingController _searchController = TextEditingController();

  bool _loading = true;
  bool _error = false;

  /// Почему не загрузилось — когда и сохранённого нет.
  LoadProblem? _problem;
  List<_Entry> _all = [];
  DateTime? _cachedAt;
  String _query = '';

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
    final body = await getDirectory();
    if (!mounted) return;
    if (body['message'] != 'Success') {
      setState(() {
        _loading = false;
        _error = true;
        _problem = problemIn(body);
      });
      return;
    }
    setState(() {
      _cachedAt = cachedAt(body);
      _all = (body['entries'] as List)
          .map((e) => _Entry.fromJson(e as Map<String, dynamic>))
          .toList();
      _loading = false;
    });
  }

  /// Ищем по всему сразу: человека ищут и по фамилии, и по должности, и по
  /// отделу, а внутренний номер иногда помнят, а имя — нет.
  ///
  /// И не придираемся к раскладке: «Аскаров» находит «Асқаров». Иначе
  /// двенадцать человек из справочника — включая Генерального директора —
  /// нельзя было найти, не переключив клавиатуру на казахскую.
  List<_Entry> get _visible {
    final query = _query.trim();
    if (query.isEmpty) return _all;
    return _all
        .where((e) =>
            matchesQuery(e.name, query) ||
            matchesQuery(e.position, query) ||
            matchesQuery(e.department, query) ||
            e.extension.contains(query))
        .toList();
  }

  Future<void> _dial(String number) async {
    // Внутренний номер набирается как есть, мобильный — без разделителей,
    // иначе часть телефонов отказывается его принимать.
    final cleaned = number.replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned.isEmpty) return;
    await openExternal(context, 'tel:$cleaned');
  }

  Future<void> _mail(String address) =>
      openExternal(context, 'mailto:$address');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.pageColor,
      drawer: const AppDrawer(),
      appBar: AppBar(
        title: BigText(content: 'directory'.tr, color: Colors.white),
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
          OfflineNotice(at: _cachedAt, onRetry: _load),
          Padding(
            padding: EdgeInsets.symmetric(
                horizontal: Dimensions.width20, vertical: 10),
            child: TextField(
              controller: _searchController,
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                hintText: 'directory_search'.tr,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      ),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error) {
      // Причина известна — общий вид, как на других экранах; нет — прежнее
      // «не удалось загрузить справочник».
      return _problem != null
          ? LoadErrorView(problem: _problem, onRetry: _load)
          : _message('directory_error'.tr, retry: true);
    }
    if (_all.isEmpty) {
      return _message('directory_empty'.tr);
    }
    final visible = _visible;
    if (visible.isEmpty) {
      return _message('directory_nothing_found'.tr);
    }

    // Заголовок отдела вставляется, когда он сменился: порядок пришёл с
    // сервера тем же, что в исходном справочнике.
    final tiles = <Widget>[];
    String? department;
    for (final entry in visible) {
      if (entry.department != department) {
        department = entry.department;
        tiles.add(_departmentHeader(department));
      }
      tiles.add(_entryTile(entry));
    }
    tiles.add(SizedBox(height: Dimensions.height30));

    return RefreshIndicator(
      color: context.accentColor,
      onRefresh: _load,
      child: ListView(children: tiles),
    );
  }

  Widget _message(String text, {bool retry = false}) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: Dimensions.width20),
            child: Text(text, textAlign: TextAlign.center),
          ),
          if (retry) ...[
            const SizedBox(height: 12),
            TextButton(onPressed: _load, child: Text('refresh'.tr)),
          ],
        ],
      ),
    );
  }

  Widget _departmentHeader(String department) {
    return Container(
      margin: EdgeInsets.only(
        top: Dimensions.height30 * 0.6,
        left: Dimensions.width20,
        right: Dimensions.width20,
        bottom: 4,
      ),
      child: Text(
        department,
        style: TextStyle(
          color: context.accentColor,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _entryTile(_Entry entry) {
    return Container(
      margin: EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 4),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: context.cardShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(entry.name,
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600)),
            if (entry.position.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(entry.position,
                  style: TextStyle(fontSize: 13, color: context.mutedColor)),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                // Каждый номер — своей кнопкой. Два телефона из одной
                // ячейки раньше стояли на одной и набирались одним числом
                // в двадцать две цифры.
                for (final number in _each(entry.extension))
                  _chip(Icons.dialpad, number, () => _dial(number)),
                for (final number in _each(entry.mobile))
                  _chip(Icons.phone_outlined, number, () => _dial(number)),
                for (final address in _each(entry.email))
                  _chip(Icons.mail_outline, address, () => _mail(address)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: context.accentColor.withOpacity(0.10),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: context.accentColor),
            const SizedBox(width: 6),
            // Длинная почта шире экрана — обрезаем на виду; по нажатию всё
            // равно уходит полный адрес.
            Flexible(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: context.accentColor)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Номера или адреса из одного поля справочника — по одному. Несколько в
/// одном поле сервер разделяет запятой.
List<String> _each(String field) => [
      for (final part in field.split(RegExp(r'[,;]')))
        if (part.trim().isNotEmpty) part.trim(),
    ];

class _Entry {
  _Entry({
    required this.department,
    required this.name,
    required this.position,
    required this.extension,
    required this.email,
    required this.mobile,
  });

  factory _Entry.fromJson(Map<String, dynamic> json) => _Entry(
        department: (json['department'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
        position: (json['position'] as String?) ?? '',
        extension: (json['extension'] as String?) ?? '',
        email: (json['email'] as String?) ?? '',
        mobile: (json['mobile'] as String?) ?? '',
      );

  final String department;
  final String name;
  final String position;
  final String extension;
  final String email;
  final String mobile;
}
