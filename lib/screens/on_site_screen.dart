import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/on_site_request.dart';
import '../utils/app_theme.dart';
import '../utils/dimensions.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';

Color onSiteColor(String status) => switch (status) {
      'inside' => const Color(0xFF2E7D32),
      'left' => const Color(0xFF546E7A),
      'away' => const Color(0xFF1565C0),
      _ => const Color(0xFFC62828),
    };

const _lateColor = Color(0xFFE65100);

/// «Кто из моих сейчас на территории»: весь отдел на сегодня — и кто прошёл
/// турникет, и кого нет, и кто из отсутствующих в отпуске или на больничном.
class OnSiteScreen extends StatefulWidget {
  const OnSiteScreen({Key? key}) : super(key: key);

  @override
  State<OnSiteScreen> createState() => _OnSiteScreenState();
}

class _OnSiteScreenState extends State<OnSiteScreen> {
  bool _loading = true;
  LoadProblem? _problem;
  OnSiteDay? _day;
  String _filter = 'all';
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final day = await fetchOnSite();
      if (!mounted) return;
      setState(() {
        _day = day;
        _problem = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _problem = problemOfAny(e);
        _loading = false;
      });
    }
  }

  bool _matches(OnSitePerson p) {
    final passes = switch (_filter) {
      'unknown' => p.unknown,
      'late' => p.late,
      'all' => true,
      _ => p.status == _filter,
    };
    if (!passes) return false;
    if (_query.isEmpty) return true;
    final text = '${p.name} ${p.department} ${p.title}'.toLowerCase();
    return _query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .every(text.contains);
  }

  @override
  Widget build(BuildContext context) {
    final day = _day;
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'onsite_title'.tr, color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'refresh'.tr,
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading && day == null
          ? const Center(child: CircularProgressIndicator())
          : day == null
              ? LoadErrorView(problem: _problem, onRetry: _load)
              : RefreshIndicator(onRefresh: _load, child: _body(day)),
    );
  }

  Widget _body(OnSiteDay day) {
    final shown = day.people.where(_matches).toList();
    final departments = {for (final p in day.people) p.department};
    final grouped = departments.length > 1;
    final filters = <(String, String)>[
      ('all', 'onsite_filter_all'.tr),
      ('unknown',
          'onsite_filter_unknown'.trParams({'n': '${day.count('absent')}'})),
      ('late', 'onsite_filter_late'.trParams({'n': '${day.count('late')}'})),
      ('inside',
          'onsite_filter_inside'.trParams({'n': '${day.count('inside')}'})),
      ('left', 'onsite_filter_left'.trParams({'n': '${day.count('left')}'})),
      ('away', 'onsite_filter_away'.trParams({'n': '${day.count('away')}'})),
    ];
    final rows = <Widget>[];
    String? lastDept;
    for (final p in shown) {
      if (grouped && p.department != lastDept) {
        lastDept = p.department;
        rows.add(Padding(
          padding: EdgeInsets.fromLTRB(Dimensions.width20, 12, 16, 4),
          child: Text(p.department,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: context.mutedColor)),
        ));
      }
      rows.add(_row(p));
    }
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text(
            'onsite_as_of'.trParams({'now': day.now, 'start': day.shiftStart}),
            style: TextStyle(fontSize: 12, color: context.mutedColor),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Text(
            day.lastEvent == null
                ? 'onsite_no_events'.tr
                : 'onsite_last_event'.trParams(
                    {'time': DateFormat('HH:mm').format(day.lastEvent!)}),
            key: const Key('onsite_freshness'),
            style: TextStyle(
                fontSize: 12,
                color: day.lastEvent == null
                    ? context.readable(_lateColor)
                    : context.mutedColor),
          ),
        ),
        SizedBox(
          height: 52,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            children: [
              for (final f in filters)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ChoiceChip(
                    key: Key('onsite_filter_${f.$1}'),
                    label: Text(f.$2),
                    selected: _filter == f.$1,
                    onSelected: (_) => setState(() => _filter = f.$1),
                  ),
                ),
            ],
          ),
        ),
        if (day.people.length > 30)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              key: const Key('onsite_search'),
              onChanged: (v) => setState(() => _query = v.trim()),
              decoration: InputDecoration(
                hintText: 'onsite_search'.tr,
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
        if (shown.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Text('onsite_empty'.tr,
                textAlign: TextAlign.center,
                style: TextStyle(color: context.mutedColor)),
          ),
        ...rows,
      ],
    );
  }

  String _statusLine(OnSitePerson p) {
    switch (p.status) {
      case 'inside':
        return 'onsite_status_inside'.trParams({'time': p.firstIn ?? ''});
      case 'left':
        return 'onsite_status_left'.trParams({'time': p.lastOut ?? ''});
      case 'away':
        final until = p.awayUntil == null
            ? ''
            : DateFormat('dd.MM').format(p.awayUntil!);
        final head =
            'away_line_${p.awayReason ?? 'other'}'.trParams({'date': until});
        return p.deputy.isEmpty
            ? head
            : '$head · ${'away_deputy_short'.trParams({'name': p.deputy})}';
      default:
        return 'onsite_status_${p.status}'.tr;
    }
  }

  Widget _row(OnSitePerson p) {
    final color = context.readable(onSiteColor(p.status));
    return Container(
      key: Key('onsite_${p.id}'),
      margin: EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 3),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: context.cardShadow,
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.name,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
                if (p.title.isNotEmpty)
                  Text(p.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontSize: 12, color: context.mutedColor)),
                const SizedBox(height: 2),
                Text.rich(TextSpan(children: [
                  TextSpan(
                      text: _statusLine(p),
                      style: TextStyle(fontSize: 12, color: color)),
                  if (p.late)
                    TextSpan(
                        text: ' · ${'onsite_late'.tr} (${p.firstIn})',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: context.readable(_lateColor))),
                ])),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
