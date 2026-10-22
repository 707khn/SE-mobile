import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';

double _number(Object? raw) => (raw as num?)?.toDouble() ?? 0;

/// План и факт статьи за один месяц.
class BudgetMonth {
  const BudgetMonth({required this.month, this.plan = 0, this.fact = 0});

  final int month;
  final double plan;
  final double fact;

  factory BudgetMonth.fromJson(Map<String, dynamic> json) => BudgetMonth(
        month: (json['month'] as num?)?.toInt() ?? 0,
        plan: _number(json['plan']),
        fact: _number(json['fact']),
      );
}

/// Статья бюджета: план и факт с начала года и по месяцам.
class BudgetArticle {
  const BudgetArticle(
      {required this.article,
      this.plan = 0,
      this.fact = 0,
      this.months = const []});

  final String article;
  final double plan;
  final double fact;
  final List<BudgetMonth> months;

  /// Факт больше плана — перерасход.
  bool get over => fact > plan + 0.5;

  factory BudgetArticle.fromJson(Map<String, dynamic> json) => BudgetArticle(
        article: '${json['article'] ?? ''}',
        plan: _number(json['plan']),
        fact: _number(json['fact']),
        months: ((json['months'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => BudgetMonth.fromJson(Map<String, dynamic>.from(m)))
            .toList(),
      );
}

class BudgetDepartment {
  const BudgetDepartment({required this.key, required this.name});

  final String key;
  final String name;
}

class BudgetReport {
  const BudgetReport({
    required this.year,
    this.all = false,
    this.years = const [],
    this.departments = const [],
    this.department = '',
    this.departmentKey = '',
    this.months = const [],
    this.asOf,
    this.plan = 0,
    this.fact = 0,
    this.articles = const [],
  });

  final int year;

  /// Видит все подразделения: руководство, ПЭО.
  final bool all;
  final List<int> years;
  final List<BudgetDepartment> departments;
  final String department;
  final String departmentKey;
  final List<int> months;
  final DateTime? asOf;
  final double plan;
  final double fact;
  final List<BudgetArticle> articles;

  factory BudgetReport.fromJson(Map<String, dynamic> json) {
    final asOf = json['as_of'];
    return BudgetReport(
      year: (json['year'] as num?)?.toInt() ?? DateTime.now().year,
      all: json['all'] == true,
      years: ((json['years'] as List?) ?? const [])
          .whereType<num>()
          .map((y) => y.toInt())
          .toList(),
      departments: ((json['departments'] as List?) ?? const [])
          .whereType<Map>()
          .map((d) => BudgetDepartment(
              key: '${d['key'] ?? ''}', name: '${d['name'] ?? ''}'))
          .toList(),
      department: '${json['department'] ?? ''}',
      departmentKey: '${json['department_key'] ?? ''}',
      months: ((json['months'] as List?) ?? const [])
          .whereType<num>()
          .map((m) => m.toInt())
          .toList(),
      asOf: asOf is String ? DateTime.tryParse(asOf)?.toLocal() : null,
      plan: _number(json['plan']),
      fact: _number(json['fact']),
      articles: ((json['articles'] as List?) ?? const [])
          .whereType<Map>()
          .map((a) => BudgetArticle.fromJson(Map<String, dynamic>.from(a)))
          .toList(),
    );
  }
}

Future<BudgetReport> fetchBudget({int? year, String? department}) async {
  try {
    final uri =
        Uri.parse('${AppValues.baseUrl}/api/budget').replace(queryParameters: {
      if (year != null) 'year': '$year',
      if (department != null && department.isNotEmpty) 'department': department,
    });
    final response = await http
        .get(uri, headers: await authHeaders())
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      throw const LoadFailure(LoadProblem.denied);
    }
    if (response.statusCode != 200) {
      throw LoadFailure(problemForStatus(response.statusCode));
    }
    return BudgetReport.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  } on LoadFailure {
    rethrow;
  } catch (e) {
    throw LoadFailure(problemOf(e), problemDetail(e));
  }
}
