import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/tech_question_request.dart';
import '../utils/app_theme.dart';
import '../utils/dimensions.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import 'tech_question_detail_screen.dart';
import 'tech_question_form_screen.dart';

Color techQuestionColor(String status) => switch (status) {
      'new' => const Color(0xFF1565C0),
      'in_work' => const Color(0xFFE65100),
      'answered' => const Color(0xFF2E7D32),
      _ => const Color(0xFF757575),
    };

class TechQuestionChip extends StatelessWidget {
  const TechQuestionChip({Key? key, required this.status}) : super(key: key);

  final String status;

  @override
  Widget build(BuildContext context) {
    final color = context.readable(techQuestionColor(status));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text('tq_status_$status'.tr,
          style: TextStyle(
              fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }
}

/// Мои вопросы, очередь ТО и решения по изделию.
class TechQuestionsScreen extends StatefulWidget {
  const TechQuestionsScreen({Key? key}) : super(key: key);

  @override
  State<TechQuestionsScreen> createState() => _TechQuestionsScreenState();
}

class _TechQuestionsScreenState extends State<TechQuestionsScreen> {
  bool _loading = true;
  bool _failed = false;
  LoadProblem? _problem;
  TechQuestionList _mine = const TechQuestionList(items: []);
  TechQuestionList? _queue;
  final _search = TextEditingController();
  List<TechQuestion>? _found;
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final mine = await fetchTechQuestions();
      final queue = mine.staff ? await fetchTechQuestions(queue: true) : null;
      if (!mounted) return;
      setState(() {
        _mine = mine;
        _queue = queue;
        _failed = false;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _problem = problemOfAny(e);
        _loading = false;
      });
    }
  }

  Future<void> _find() async {
    final product = _search.text.trim();
    if (product.isEmpty) return;
    setState(() => _searching = true);
    List<TechQuestion> found;
    try {
      found = (await fetchTechQuestions(product: product)).items;
    } catch (_) {
      found = const [];
    }
    if (!mounted) return;
    setState(() {
      _found = found;
      _searching = false;
    });
  }

  Future<void> _open(TechQuestion item) async {
    await Get.to(() => TechQuestionDetailScreen(questionId: item.id));
    if (mounted) _load();
  }

  Future<void> _create() async {
    final created =
        await Get.to<TechQuestion>(() => const TechQuestionFormScreen());
    if (!mounted) return;
    _load();
    if (created != null) _open(created);
  }

  @override
  Widget build(BuildContext context) {
    final queue = _queue;
    final history = _mine.history;
    final tabs = [
      if (queue != null)
        Tab(
            text: queue.waiting > 0
                ? '${'tq_tab_queue'.tr} (${queue.waiting})'
                : 'tq_tab_queue'.tr),
      Tab(text: 'tq_tab_mine'.tr),
      if (history) Tab(text: 'tq_tab_history'.tr),
    ];
    final views = [
      if (queue != null) _list(queue.items, 'tq_empty_queue'.tr, staff: true),
      _list(_mine.items, 'tq_empty_mine'.tr),
      if (history) _historyTab(),
    ];
    return DefaultTabController(
      key: ValueKey(tabs.length),
      length: tabs.length,
      child: Scaffold(
        backgroundColor: context.pageColor,
        appBar: AppBar(
          title: BigText(content: 'tq_title'.tr, color: Colors.white),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'refresh'.tr,
              onPressed: _loading ? null : _load,
            ),
          ],
          bottom: tabs.length > 1
              ? TabBar(
                  labelColor: Colors.white,
                  unselectedLabelColor: Colors.white70,
                  indicatorColor: Colors.white,
                  tabs: tabs,
                )
              : null,
        ),
        floatingActionButton: FloatingActionButton.extended(
          key: const Key('tq_new'),
          onPressed: _create,
          icon: const Icon(Icons.help_outline),
          label: Text('tq_new'.tr),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _failed
                ? LoadErrorView(problem: _problem, onRetry: _load)
                : tabs.length > 1
                    ? TabBarView(children: views)
                    : views.single,
      ),
    );
  }

  Widget _historyTab() {
    final found = _found;
    return ListView(
      padding: const EdgeInsets.only(bottom: 88),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            key: const Key('tq_search'),
            controller: _search,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _find(),
            decoration: InputDecoration(
              hintText: 'tq_history_hint'.tr,
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: IconButton(
                key: const Key('tq_search_go'),
                icon: _searching
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.arrow_forward),
                onPressed: _searching ? null : _find,
              ),
            ),
          ),
        ),
        if (found != null && found.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text('tq_history_empty'.tr,
                textAlign: TextAlign.center,
                style: TextStyle(color: context.mutedColor)),
          ),
        for (final item in found ?? const <TechQuestion>[])
          _row(item, false, showDecision: true),
      ],
    );
  }

  Widget _list(List<TechQuestion> items, String empty, {bool staff = false}) {
    return RefreshIndicator(
      onRefresh: _load,
      child: items.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(32),
              children: [
                Icon(Icons.engineering_outlined,
                    size: 56, color: context.mutedColor),
                const SizedBox(height: 12),
                Text(empty,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.mutedColor)),
              ],
            )
          : ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(top: 8, bottom: 88),
              itemCount: items.length,
              itemBuilder: (_, i) => _row(items[i], staff),
            ),
    );
  }

  Widget _row(TechQuestion item, bool staff, {bool showDecision = false}) {
    final when = item.createdAt == null
        ? ''
        : DateFormat('dd.MM.yy').format(item.createdAt!);
    // Ждёт этого человека: ТО — новое и уточнённое, автора — решение.
    final waiting = staff
        ? item.status == 'new' || item.status == 'in_work'
        : item.status == 'answered' && item.isAuthor;
    return Container(
      margin: EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 4),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: context.cardShadow,
        border: waiting
            ? Border(
                left: BorderSide(
                    color: item.urgent
                        ? const Color(0xFFC62828)
                        : techQuestionColor(item.status),
                    width: 3))
            : null,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _open(item),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                        '${item.urgent && item.status != 'closed' ? '⚠ ' : ''}'
                        '${item.product}',
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                  ),
                  TechQuestionChip(status: item.status),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                [
                  'tq_kind_${item.kind}'.tr,
                  if (item.where.isNotEmpty) item.where,
                ].join(' · '),
                style: TextStyle(fontSize: 12, color: context.mutedColor),
              ),
              const SizedBox(height: 4),
              Text(
                  showDecision && item.decision.isNotEmpty
                      ? '${'tq_decision'.tr}: ${item.decision}'
                      : item.text,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 4),
              Text(
                [
                  when,
                  if (item.author != null && !item.isAuthor) item.author!.short,
                ].where((s) => s.isNotEmpty).join(' · '),
                style: TextStyle(fontSize: 11, color: context.mutedColor),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
