import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/iso_day.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';
import 'assignment_request.dart' show AssignPerson;

/// Пункты плана — в том же порядке, что и на сервере.
const onboardingSteps = [
  'account',
  'pass',
  'induction',
  'clothing',
  'workplace',
  'mentor'
];

DateTime? _time(Object? raw) =>
    raw is String ? DateTime.tryParse(raw)?.toLocal() : null;

AssignPerson? _person(Object? raw) =>
    raw is Map ? AssignPerson.fromJson(Map<String, dynamic>.from(raw)) : null;

class OnboardingStep {
  const OnboardingStep(
      {required this.step,
      this.done = false,
      this.doneAt,
      this.doneBy,
      this.note = '',
      this.canMark = false});

  final String step;
  final bool done;
  final DateTime? doneAt;
  final AssignPerson? doneBy;
  final String note;
  final bool canMark;

  factory OnboardingStep.fromJson(Map<String, dynamic> json) => OnboardingStep(
        step: '${json['step'] ?? ''}',
        done: json['done'] == true,
        doneAt: _time(json['done_at']),
        doneBy: _person(json['done_by']),
        note: '${json['note'] ?? ''}',
        canMark: json['can_mark'] == true,
      );
}

class Onboarding {
  const Onboarding({
    required this.id,
    this.employee,
    this.mentor,
    this.startDate,
    this.note = '',
    this.status = 'active',
    this.steps = const [],
    this.isMine = false,
    this.canManage = false,
  });

  final int id;
  final AssignPerson? employee;
  final AssignPerson? mentor;
  final DateTime? startDate;
  final String note;
  final String status;
  final List<OnboardingStep> steps;
  final bool isMine;
  final bool canManage;

  int get doneCount => steps.where((s) => s.done).length;

  factory Onboarding.fromJson(Map<String, dynamic> json) => Onboarding(
        id: (json['id'] as num?)?.toInt() ?? 0,
        employee: _person(json['employee']),
        mentor: _person(json['mentor']),
        startDate: DateTime.tryParse('${json['start_date'] ?? ''}'),
        note: '${json['note'] ?? ''}',
        status: '${json['status'] ?? 'active'}',
        steps: ((json['steps'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => OnboardingStep.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        isMine: json['is_mine'] == true,
        canManage: json['can_manage'] == true,
      );
}

class OnboardingList {
  const OnboardingList({this.hr = false, this.mine, this.items = const []});

  final bool hr;
  final Onboarding? mine;
  final List<Onboarding> items;

  factory OnboardingList.fromJson(Map<String, dynamic> json) => OnboardingList(
        hr: json['hr'] == true,
        mine: json['mine'] is Map
            ? Onboarding.fromJson(Map<String, dynamic>.from(json['mine']))
            : null,
        items: ((json['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Onboarding.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );
}

class OnboardingResult {
  const OnboardingResult({this.item, this.error, this.problem});

  final Onboarding? item;
  final String? error;
  final LoadProblem? problem;

  bool get ok => item != null;
}

Uri _uri(String path) => Uri.parse('${AppValues.baseUrl}$path');

Future<Map<String, dynamic>> _get(String path) async {
  try {
    final response = await http
        .get(_uri(path), headers: await authHeaders())
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      throw const LoadFailure(LoadProblem.denied);
    }
    if (response.statusCode != 200) {
      throw LoadFailure(problemForStatus(response.statusCode));
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  } on LoadFailure {
    rethrow;
  } catch (e) {
    throw LoadFailure(problemOf(e), problemDetail(e));
  }
}

Future<OnboardingList> fetchOnboardings() async =>
    OnboardingList.fromJson(await _get('/api/onboarding'));

Future<Onboarding> fetchOnboarding(int id) async {
  final body = await _get('/api/onboarding/$id');
  return Onboarding.fromJson(body['item'] as Map<String, dynamic>);
}

Future<List<AssignPerson>> searchOnboardingPeople(String query) async {
  final body =
      await _get('/api/onboarding/people?q=${Uri.encodeQueryComponent(query)}');
  return ((body['people'] as List?) ?? const [])
      .whereType<Map>()
      .map((e) => AssignPerson.fromJson(Map<String, dynamic>.from(e)))
      .toList();
}

Future<OnboardingResult> _post(String path, Map<String, Object?> body) async {
  try {
    final response = await http
        .post(_uri(path), headers: await authHeaders(), body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return const OnboardingResult(problem: LoadProblem.denied);
    }
    Map<String, dynamic> parsed = const {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) parsed = decoded;
    } catch (_) {}
    if ((response.statusCode == 200 || response.statusCode == 201) &&
        parsed['item'] is Map) {
      return OnboardingResult(
          item: Onboarding.fromJson(Map<String, dynamic>.from(parsed['item'])));
    }
    final error = parsed['error'];
    return OnboardingResult(
        error: error is String ? error : null,
        problem: problemForStatus(response.statusCode));
  } catch (e) {
    return OnboardingResult(problem: problemOf(e));
  }
}

Future<OnboardingResult> createOnboarding({
  required String employeeId,
  required DateTime startDate,
  String? mentorId,
  required List<String> steps,
  String note = '',
}) =>
    _post('/api/onboarding', {
      'employee_id': employeeId,
      'start_date': isoDay(startDate),
      if (mentorId != null) 'mentor_id': mentorId,
      'steps': steps,
      if (note.isNotEmpty) 'note': note,
    });

Future<OnboardingResult> markOnboardingStep(int id, String step, bool done,
        {String note = ''}) =>
    _post('/api/onboarding/$id', {
      'action': 'step',
      'step': step,
      'done': done,
      if (note.isNotEmpty) 'note': note,
    });

Future<OnboardingResult> changeOnboardingMentor(int id, String mentorId) =>
    _post('/api/onboarding/$id', {'action': 'mentor', 'mentor_id': mentorId});

Future<OnboardingResult> cancelOnboarding(int id) =>
    _post('/api/onboarding/$id', {'action': 'cancel'});
