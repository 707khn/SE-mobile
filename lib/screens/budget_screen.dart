import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/budget_request.dart';
import '../utils/app_theme.dart';
import '../utils/lang.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';

/// «1 234 567» — тенге без копеек: в план-факте копейки только мешают.
String budgetMoney(double value) {
  final digits = value.round().abs().toString();
  final grouped =
      digits.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ' ');
  return value.round() < 0 ? '−$grouped' : grouped;
}

String _monthName(int month) {
  final name = DateFormat('LLLL', Lang.dates).format(DateTime(2000, month));
  return name.isEmpty ? '$month' : name[0].toUpperCase() + name.substring(1);
}

int _percent(double fact, double plan) =>
    plan <= 0 ? (fact > 0 ? 100 : 0) : (fact / plan * 100).round();

const _overColor = Color(0xFFC62828);
const _okColor = Color(0xFF2E7D32);

/// План-факт бюджета: свои статьи — начальнику, все — руководству и ПЭО.
class BudgetScreen extends StatefulWidget {
  const BudgetScreen({Key? key}) : super(key: key);

  @override
  State<BudgetScreen> createState() => _BudgetScreenState();
}

class _BudgetScreenState extends State<BudgetScreen> {
  bool _loading = true;
  LoadProblem? _problem;
  BudgetReport? _report;
  int? _year;
  String? _department;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final report = await fetchBudget(year: _year, department: _department);
      if (!mounted) return;
      setState(() {
        _report = report;
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

  @override
  Widget build(BuildContext context) {
    final report = _report;
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'bg_title'.tr, color: Colors.white),
        actions: [
          if (report != null && report.years.length > 1)
            PopupMenuButton<int>(
              key: const Key('bg_years'),
              icon: const Icon(Icons.calendar_month_outlined),
              onSelected: (year) {
                _year = year;
                _load();
              },
              itemBuilder: (_) => [
                for (final y in report.years)
                  PopupMenuItem(
                      key: Key('bg_year_$y'),
                      value: y,
                      child: Text('bg_year'.trParams({'year': '$y'}))),
              ],
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'refresh'.tr,
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading && report == null
          ? const Center(child: CircularProgressIndicator())
          : _problem != null || report == null
              ? LoadErrorView(problem: _problem, onRetry: _load)
              : RefreshIndicator(onRefresh: _load, child: _body(report)),
    );
  }

  Widget _body(BudgetReport report) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (report.all && report.departments.length > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: DropdownButtonFormField<String>(
              key: const Key('bg_department'),
              value: report.departmentKey,
              isExpanded: true,
              decoration: InputDecoration(labelText: 'bg_department'.tr),
              items: [
                for (final d in report.departments)
                  DropdownMenuItem(
                      value: d.key,
                      child: Text(d.name, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (key) {
                if (key == null || key == report.departmentKey) return;
                _department = key;
                _year = report.year;
                _load();
              },
            ),
          ),
        if (report.articles.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text('bg_empty'.trParams({'year': '${report.year}'}),
                textAlign: TextAlign.center),
          )
        else ...[
          _summary(report),
          for (final (i, article) in report.articles.indexed)
            _article(i, article),
        ],
      ],
    );
  }

  Widget _summary(BudgetReport report) {
    final left = report.plan - report.fact;
    final over = left < -0.5;
    final ratio = report.plan <= 0 ? 1.0 : report.fact / report.plan;
    final color = context.readable(over ? _overColor : _okColor);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(report.department,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              [
                'bg_year'.trParams({'year': '${report.year}'}),
                'bg_months'.trParams(
                    {'months': report.months.map(_monthName).join(', ')}),
              ].join(' · '),
              style: const TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _figure('bg_plan'.tr, report.plan)),
              Expanded(child: _figure('bg_fact'.tr, report.fact)),
              Expanded(
                child: _figure(over ? 'bg_over'.tr : 'bg_left'.tr, left.abs(),
                    color: color, key: const Key('bg_total_left')),
              ),
            ]),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: ratio.clamp(0.0, 1.0),
              color: color,
              backgroundColor: color.withOpacity(0.15),
              minHeight: 6,
            ),
            if (report.asOf != null) ...[
              const SizedBox(height: 8),
              Text(
                'bg_as_of'.trParams({
                  'date': DateFormat('dd.MM.yyyy HH:mm').format(report.asOf!)
                }),
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _figure(String label, double value, {Color? color, Key? key}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          Text(budgetMoney(value),
              key: key,
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w600, color: color)),
        ],
      );

  Widget _article(int index, BudgetArticle article) {
    final color = context.readable(article.over ? _overColor : _okColor);
    final left = article.plan - article.fact;
    return ExpansionTile(
      key: Key('bg_article_$index'),
      title: Text(article.article),
      subtitle: Text('bg_article_line'.trParams({
        'fact': budgetMoney(article.fact),
        'plan': budgetMoney(article.plan),
        'percent': '${_percent(article.fact, article.plan)}',
      })),
      trailing: Text(
        budgetMoney(left),
        key: Key('bg_left_$index'),
        style: TextStyle(color: color, fontWeight: FontWeight.w600),
      ),
      children: [
        for (final m in article.months)
          ListTile(
            dense: true,
            title: Text(_monthName(m.month)),
            subtitle: Text('bg_month_line'.trParams({
              'plan': budgetMoney(m.plan),
              'fact': budgetMoney(m.fact),
            })),
            trailing: Text(budgetMoney(m.plan - m.fact),
                style: TextStyle(
                    color: context.readable(
                        m.fact > m.plan + 0.5 ? _overColor : _okColor))),
          ),
      ],
    );
  }
}
