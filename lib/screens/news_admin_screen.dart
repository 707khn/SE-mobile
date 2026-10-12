import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/news_request.dart';
import '../utils/app_theme.dart';
import '../utils/dimensions.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';

/// Очередь объявлений и управление лентой — для администратора.
///
/// Письма из рассылки приходят сюда неопубликованными: то, что писалось для
/// отдела, не должно само уезжать на пятьсот экранов. Здесь их читают и
/// решают, показывать ли.
class NewsAdminScreen extends StatefulWidget {
  const NewsAdminScreen({Key? key}) : super(key: key);

  @override
  State<NewsAdminScreen> createState() => _NewsAdminScreenState();
}

class _NewsAdminScreenState extends State<NewsAdminScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _items = [];
  int _pending = 0;

  /// Очередь не загрузилась. Раньше экран писал «пока новостей нет» — и
  /// администратор не знал, что объявления ждут его, а не кончились.
  bool _failed = false;
  LoadProblem? _problem;

  /// Набранное объявление живёт, пока не опубликовано. Прежде оно жило в
  /// окне: не ушло на сервер — и текст пропадал вместе с окном, писать
  /// заново.
  final _draftTitle = TextEditingController();
  final _draftText = TextEditingController();

  @override
  void dispose() {
    _draftTitle.dispose();
    _draftText.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final body = await getNewsQueue();
    if (!mounted) return;
    setState(() {
      _failed = body['message'] == 'Failure';
      _problem = problemIn(body);
      _items = ((body['items'] as List?) ?? [])
          .map((e) => e as Map<String, dynamic>)
          .toList();
      _pending = (body['pending'] as int?) ?? 0;
      _loading = false;
    });
  }

  Future<void> _compose() async {
    final titleController = _draftTitle;
    final textController = _draftText;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('news_new'.tr),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                decoration: InputDecoration(
                    labelText: 'news_title'.tr, isDense: true),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: textController,
                maxLines: 5,
                decoration: InputDecoration(
                    labelText: 'news_text'.tr, isDense: true),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('cancel'.tr)),
          // Без заголовка публиковать нечего: прежде окно закрывалось и
          // молча выбрасывало набранный текст.
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: titleController,
            builder: (context, title, _) => TextButton(
                onPressed: title.text.trim().isEmpty
                    ? null
                    : () => Navigator.pop(context, true),
                child: Text('publish'.tr)),
          ),
        ],
      ),
    );
    if (saved != true) return;
    final ok = await createAnnouncement(
        titleController.text.trim(), textController.text.trim());
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('news_save_failed'.tr),
        action: SnackBarAction(label: 'try_again'.tr, onPressed: _compose),
      ));
      return;
    }
    titleController.clear();
    textController.clear();
    _load();
  }

  Future<void> _setPublished(Map<String, dynamic> item, bool published) async {
    final ok = await setNewsPublished(item['id'] as int, published);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('news_save_failed'.tr)));
      return;
    }
    _load();
  }

  Future<void> _remove(Map<String, dynamic> item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('news_delete'.tr),
        content: Text(item['title'] as String? ?? ''),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('cancel'.tr)),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('news_delete'.tr)),
        ],
      ),
    );
    if (confirmed != true) return;
    final ok = await deleteNews(item['id'] as int);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('news_save_failed'.tr)));
      return;
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'news_manage'.tr, color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'refresh'.tr,
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _compose,
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _failed
              ? LoadErrorView(problem: _problem, onRetry: _load)
          : Column(
              children: [
                if (_pending > 0)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    color: context.accentColor.withOpacity(0.10),
                    child: Text(
                      'news_pending'.trParams({'count': '$_pending'}),
                      style: TextStyle(color: context.accentColor),
                    ),
                  ),
                Expanded(
                  child: _items.isEmpty
                      ? Center(child: Text('news_empty'.tr))
                      : ListView.builder(
                          itemCount: _items.length,
                          itemBuilder: (_, i) => _row(_items[i]),
                        ),
                ),
              ],
            ),
    );
  }

  Widget _row(Map<String, dynamic> item) {
    final published = item['is_published'] == true;
    final moment = DateTime.tryParse((item['published_at'] as String?) ?? '');
    final isSite = item['source'] == 'site';
    return Container(
      margin: EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 4),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: context.cardShadow,
        // Ждущие одобрения отмечены полосой слева: их видно, не читая.
        border: published
            ? null
            : Border(left: BorderSide(color: context.accentColor, width: 3)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${isSite ? 'news_from_site'.tr : 'news_announcement'.tr}'
                    '${moment == null ? '' : ' · ${DateFormat('dd.MM.yyyy').format(moment.toLocal())}'}',
                    style: TextStyle(fontSize: 11, color: context.mutedColor),
                  ),
                  const SizedBox(height: 4),
                  Text(item['title'] as String? ?? '',
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                  if ((item['summary'] as String? ?? '').isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(item['summary'] as String,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: context.mutedColor)),
                  ],
                ],
              ),
            ),
            IconButton(
              icon: Icon(published ? Icons.visibility : Icons.check_circle,
                  color: published ? context.mutedColor : context.accentColor),
              tooltip: published ? 'news_hide'.tr : 'news_approve'.tr,
              onPressed: () => _setPublished(item, !published),
            ),
            IconButton(
              icon: Icon(Icons.delete_outline, color: context.mutedColor),
              tooltip: 'news_delete'.tr,
              onPressed: () => _remove(item),
            ),
          ],
        ),
      ),
    );
  }
}
