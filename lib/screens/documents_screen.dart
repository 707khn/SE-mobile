import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../requests/documents_request.dart';
import '../utils/app_theme.dart';
import '../utils/dimensions.dart';
import '../utils/load_problem.dart';
import '../utils/offline_cache.dart';
import '../widgets/app_drawer.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import '../widgets/offline_notice.dart';
import 'document_acks_screen.dart';

/// Документы предприятия: приказы, положения, графики, образцы заявлений.
///
/// Сверху — то, с чем человек ещё должен ознакомиться: ради этого раздел
/// и открывают. Дальше — всё по разделам, свежие первыми.
class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({Key? key}) : super(key: key);

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen> {
  bool _loading = true;
  LoadProblem? _problem;
  bool _error = false;
  DateTime? _cachedAt;
  bool _canEdit = false;
  List<CompanyDocument> _docs = [];
  List<Map<String, dynamic>> _categories = [];

  /// Какой документ сейчас скачивается — чтобы не нажать дважды.
  int? _opening;

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
    final body = await getDocuments();
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
      _canEdit = body['can_edit'] == true;
      _categories = ((body['categories'] as List?) ?? [])
          .whereType<Map<String, dynamic>>()
          .toList();
      _docs = ((body['items'] as List?) ?? [])
          .whereType<Map<String, dynamic>>()
          .map(CompanyDocument.fromJson)
          .toList();
      _loading = false;
    });
  }

  void _replace(CompanyDocument updated) {
    setState(() {
      _docs = [for (final d in _docs) d.id == updated.id ? updated : d];
    });
  }

  /// Скачать во временную папку. Папка своя и чистится перед каждым
  /// открытием: приказы не должны копиться на телефоне.
  Future<File?> _download(CompanyDocument doc) async {
    setState(() => _opening = doc.id);
    try {
      final bytes = await downloadDocument(doc.id);
      if (bytes == null) return null;
      final dir = Directory('${(await getTemporaryDirectory()).path}/documents');
      if (await dir.exists()) await dir.delete(recursive: true);
      await dir.create(recursive: true);
      final file = File('${dir.path}/${_fileName(doc)}');
      await file.writeAsBytes(bytes, flush: true);
      return file;
    } catch (_) {
      return null;
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  String _fileName(CompanyDocument doc) {
    final name = doc.filename.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return name.isEmpty ? 'document' : name;
  }

  void _say(String text) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _open(CompanyDocument doc) async {
    if (_opening != null) return;
    final file = await _download(doc);
    if (!mounted) return;
    if (file == null) {
      _say('documents_download_failed'.tr);
      return;
    }
    final result = await OpenFile.open(file.path);
    if (!mounted) return;
    if (result.type == ResultType.noAppToOpen) {
      _say('export_no_app'.tr);
    } else if (result.type != ResultType.done) {
      _say('url_error'.tr);
    }
  }

  Future<void> _share(CompanyDocument doc) async {
    if (_opening != null) return;
    final file = await _download(doc);
    if (!mounted) return;
    if (file == null) {
      _say('documents_download_failed'.tr);
      return;
    }
    await Share.shareXFiles([XFile(file.path, name: _fileName(doc))],
        subject: doc.title);
  }

  Future<void> _acknowledge(CompanyDocument doc) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('documents_ack_title'.tr),
        content: Text('documents_ack_confirm'.trParams({'title': doc.title})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('cancel'.tr),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('documents_ack'.tr),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    HapticFeedback.mediumImpact();
    final updated = await acknowledgeDocument(doc.id);
    if (!mounted) return;
    if (updated == null) {
      _say('documents_ack_failed'.tr);
      return;
    }
    _replace(updated);
    _say('documents_ack_done'.tr);
  }

  Future<void> _delete(CompanyDocument doc) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('documents_delete'.tr),
        content: Text(doc.title),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('cancel'.tr),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('documents_delete'.tr,
                style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    if (await deleteDocument(doc.id)) {
      _load();
    } else if (mounted) {
      _say('documents_change_failed'.tr);
    }
  }

  Future<void> _toggleAck(CompanyDocument doc) async {
    if (await setDocumentRequiresAck(doc.id, !doc.requiresAck)) {
      _load();
    } else if (mounted) {
      _say('documents_change_failed'.tr);
    }
  }

  /// Всё, что можно сделать с документом, — в одном листе снизу.
  void _actions(CompanyDocument doc) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        void run(Future<void> Function() action) {
          Navigator.pop(ctx);
          action();
        }

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                child: Text(doc.title,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(_subtitle(doc),
                    style: TextStyle(fontSize: 13, color: context.mutedColor)),
              ),
              ListTile(
                leading: const Icon(Icons.open_in_new),
                title: Text('documents_open'.tr),
                onTap: () => run(() => _open(doc)),
              ),
              ListTile(
                leading: const Icon(Icons.share_outlined),
                title: Text('documents_share'.tr),
                onTap: () => run(() => _share(doc)),
              ),
              if (doc.awaitingAck)
                ListTile(
                  leading: Icon(Icons.task_alt, color: context.accentColor),
                  title: Text('documents_ack'.tr,
                      style: TextStyle(color: context.accentColor)),
                  onTap: () => run(() => _acknowledge(doc)),
                ),
              if (_canEdit) ...[
                const Divider(height: 1),
                if (doc.requiresAck)
                  ListTile(
                    leading: const Icon(Icons.fact_check_outlined),
                    title: Text('documents_who_acked'.tr),
                    onTap: () => run(() async {
                      await Get.to(() => DocumentAcksScreen(document: doc));
                    }),
                  ),
                ListTile(
                  leading: Icon(doc.requiresAck
                      ? Icons.remove_done
                      : Icons.playlist_add_check),
                  title: Text(doc.requiresAck
                      ? 'documents_ack_off'.tr
                      : 'documents_ack_on'.tr),
                  onTap: () => run(() => _toggleAck(doc)),
                ),
                ListTile(
                  leading: Icon(Icons.delete_outline, color: Colors.red.shade700),
                  title: Text('documents_delete'.tr,
                      style: TextStyle(color: Colors.red.shade700)),
                  onTap: () => run(() => _delete(doc)),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  String _subtitle(CompanyDocument doc) {
    final parts = <String>[
      if (doc.number.isNotEmpty) '№ ${doc.number}',
      if (doc.date != null) DateFormat('dd.MM.yyyy').format(doc.date!),
      '${doc.extension.toUpperCase()}, ${documentSize(doc.size)}',
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.pageColor,
      drawer: const AppDrawer(),
      appBar: AppBar(
        title: BigText(content: 'documents'.tr, color: Colors.white),
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
          OfflineNotice(at: _cachedAt),
          if (_opening != null) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error) {
      return LoadErrorView(problem: _problem, onRetry: _load);
    }
    if (_docs.isEmpty) {
      return Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: Dimensions.width20),
          child: Text(
              _canEdit ? 'documents_empty_editor'.tr : 'documents_empty'.tr,
              textAlign: TextAlign.center),
        ),
      );
    }
    final waiting = _docs.where((d) => d.awaitingAck).toList();
    final sections = groupDocuments(_docs, _categories);
    return RefreshIndicator(
      color: context.accentColor,
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.only(bottom: Dimensions.height30),
        children: [
          if (waiting.isNotEmpty) ...[
            _header('documents_waiting'.trParams({'count': '${waiting.length}'}),
                highlight: true),
            for (final doc in waiting) _card(doc),
          ],
          for (final section in sections) ...[
            _header(section.name),
            for (final doc in section.documents) _card(doc),
          ],
        ],
      ),
    );
  }

  Widget _header(String text, {bool highlight = false}) {
    return Padding(
      padding: EdgeInsets.fromLTRB(Dimensions.width20, 18, Dimensions.width20, 6),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
          color: highlight ? Colors.orange.shade800 : context.mutedColor,
        ),
      ),
    );
  }

  IconData _icon(CompanyDocument doc) {
    switch (doc.extension) {
      case 'pdf':
        return Icons.picture_as_pdf_outlined;
      case 'xls':
      case 'xlsx':
        return Icons.table_chart_outlined;
      case 'jpg':
      case 'jpeg':
      case 'png':
        return Icons.image_outlined;
      default:
        return Icons.description_outlined;
    }
  }

  Widget _card(CompanyDocument doc) {
    final acked = doc.ackedAt;
    return Container(
      margin: EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 4),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: context.cardShadow,
        border: doc.awaitingAck
            ? Border.all(color: Colors.orange.shade700, width: 1.2)
            : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(doc),
        onLongPress: () => _actions(doc),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: _opening == doc.id
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(_icon(doc), color: context.accentColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(doc.title,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(_subtitle(doc),
                        style:
                            TextStyle(fontSize: 12, color: context.mutedColor)),
                    if (doc.requiresAck) ...[
                      const SizedBox(height: 8),
                      if (acked != null)
                        Row(
                          children: [
                            Icon(Icons.check_circle,
                                size: 16, color: Colors.green.shade700),
                            const SizedBox(width: 6),
                            Text(
                              'documents_acked_on'.trParams({
                                'date': DateFormat('dd.MM.yyyy')
                                    .format(acked.toLocal())
                              }),
                              style: TextStyle(
                                  fontSize: 12, color: Colors.green.shade700),
                            ),
                          ],
                        )
                      else
                        OutlinedButton.icon(
                          onPressed: () => _acknowledge(doc),
                          icon: const Icon(Icons.task_alt, size: 18),
                          label: Text('documents_ack'.tr),
                        ),
                    ],
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.more_vert),
                tooltip: 'documents_more'.tr,
                onPressed: () => _actions(doc),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
