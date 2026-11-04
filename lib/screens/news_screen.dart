import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../utils/desktop.dart';
import 'package:intl/intl.dart';

import '../requests/news_request.dart';
import '../utils/app_theme.dart';
import '../utils/dimensions.dart';
import '../utils/role_helper.dart';
import '../utils/offline_cache.dart';
import '../utils/open_external.dart';
import '../widgets/offline_notice.dart';
import '../widgets/app_drawer.dart';
import '../widgets/custom_text.dart';
import '../utils/load_problem.dart';
import '../widgets/load_error_view.dart';
import 'news_admin_screen.dart';

/// Лента предприятия: новости с сайта и объявления.
///
/// Оба вида в одном списке и по одной дате: человеку неважно, откуда пришло
/// сообщение, важно — когда. Откуда, показывает пометка на карточке.
class NewsScreen extends StatefulWidget {
  const NewsScreen({Key? key, this.job = ''}) : super(key: key);

  final String job;

  @override
  State<NewsScreen> createState() => _NewsScreenState();
}

class _NewsScreenState extends State<NewsScreen> {
  bool _loading = true;
  bool _error = false;

  /// Почему не загрузилось — когда и сохранённого нет.
  LoadProblem? _problem;
  List<_NewsItem> _items = [];
  DateTime? _cachedAt;

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
    final body = await getNews();
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
      _items = (body['items'] as List)
          .map((e) => _NewsItem.fromJson(e as Map<String, dynamic>))
          .toList();
      _loading = false;
    });
  }

  Future<void> _open(String url) async {
    if (url.isEmpty) return;
    await openExternal(context, url);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.pageColor,
      drawer: sidebarShown(context) ? null : const AppDrawer(),
      appBar: AppBar(
        title: BigText(content: 'news'.tr, color: Colors.white),
        actions: [
          if (isSystemAdmin(widget.job))
            IconButton(
              icon: const Icon(Icons.edit_note),
              tooltip: 'news_manage'.tr,
              onPressed: () async {
                await Get.to(() => const NewsAdminScreen());
                _load();
              },
            ),
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
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error && _problem != null) {
      return LoadErrorView(problem: _problem, onRetry: _load);
    }
    if (_error) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('news_error'.tr),
            const SizedBox(height: 12),
            TextButton(onPressed: _load, child: Text('refresh'.tr)),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: Dimensions.width20),
          child: Text('news_empty'.tr, textAlign: TextAlign.center),
        ),
      );
    }
    return RefreshIndicator(
      color: context.accentColor,
      onRefresh: _load,
      child: ListView.builder(
        padding: EdgeInsets.only(bottom: Dimensions.height30),
        itemCount: _items.length,
        itemBuilder: (_, index) => _card(_items[index]),
      ),
    );
  }

  Widget _card(_NewsItem item) {
    final isSite = item.source == 'site';
    return Container(
      margin: EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 6),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: context.cardShadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: item.url.isEmpty ? null : () => _open(item.url),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (item.imageUrl.isNotEmpty)
              // Картинка необязательна: не загрузилась — карточка остаётся
              // читаемой, а не ломается пустым серым прямоугольником.
              Image.network(
                item.imageUrl,
                width: double.infinity,
                height: 160,
                fit: BoxFit.cover,
                // В браузере картинка с сайта компании приходит без
                // разрешения CORS, и нарисовать её сам Flutter не может —
                // тогда её показывает браузер обычным <img>.
                webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: context.accentColor.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          isSite ? 'news_from_site'.tr : 'news_announcement'.tr,
                          style: TextStyle(
                              fontSize: 11, color: context.accentColor),
                        ),
                      ),
                      const Spacer(),
                      Text(
                        _when(item.publishedAt),
                        style: TextStyle(
                            fontSize: 12, color: context.mutedColor),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(item.title,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                  if (item.summary.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(item.summary,
                        style: TextStyle(
                            fontSize: 13, color: context.mutedColor)),
                  ],
                  if (item.author.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(item.author,
                        style: TextStyle(
                            fontSize: 12,
                            fontStyle: FontStyle.italic,
                            color: context.mutedColor)),
                  ],
                  if (item.url.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Icon(Icons.open_in_new,
                            size: 14, color: context.accentColor),
                        const SizedBox(width: 6),
                        Text('news_read'.tr,
                            style: TextStyle(
                                fontSize: 13, color: context.accentColor)),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _when(DateTime? moment) {
    if (moment == null) return '';
    final now = DateTime.now();
    final local = moment.toLocal();
    final days = DateTime(now.year, now.month, now.day)
        .difference(DateTime(local.year, local.month, local.day))
        .inDays;
    if (days == 0) return 'today'.tr;
    if (days == 1) return 'yesterday'.tr;
    return DateFormat('dd.MM.yyyy').format(local);
  }
}

class _NewsItem {
  _NewsItem({
    required this.id,
    required this.source,
    required this.title,
    required this.summary,
    required this.url,
    required this.imageUrl,
    required this.author,
    required this.publishedAt,
  });

  factory _NewsItem.fromJson(Map<String, dynamic> json) => _NewsItem(
        id: (json['id'] as int?) ?? 0,
        source: (json['source'] as String?) ?? 'announcement',
        title: (json['title'] as String?) ?? '',
        summary: (json['summary'] as String?) ?? '',
        url: (json['url'] as String?) ?? '',
        imageUrl: (json['image_url'] as String?) ?? '',
        author: (json['author'] as String?) ?? '',
        publishedAt: DateTime.tryParse((json['published_at'] as String?) ?? ''),
      );

  final int id;
  final String source;
  final String title;
  final String summary;
  final String url;
  final String imageUrl;
  final String author;
  final DateTime? publishedAt;
}
