import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';
import 'person.dart' show ItEvent, ItPerson;

const tripTransports = [
  'train',
  'plane',
  'bus',
  'company_car',
  'own_car',
  'other'
];
const tripCategories = ['travel', 'lodging', 'per_diem', 'other'];

int? _int(Object? raw) => (raw as num?)?.toInt();

/// 150000 → «150 000 ₸».
String tenge(int value) {
  final digits = value.abs().toString();
  final groups = <String>[];
  for (var end = digits.length; end > 0; end -= 3) {
    groups.insert(0, digits.substring(end - 3 < 0 ? 0 : end - 3, end));
  }
  return '${value < 0 ? '−' : ''}${groups.join(' ')} ₸';
}

class TripExpense {
  const TripExpense(
      {required this.id,
      required this.category,
      required this.amount,
      this.document = ''});

  final int id;
  final String category;
  final int amount;
  final String document;

  static TripExpense? fromJson(Object? raw) {
    if (raw is! Map) return null;
    return TripExpense(
      id: _int(raw['id']) ?? 0,
      category: '${raw['category'] ?? 'other'}',
      amount: _int(raw['amount']) ?? 0,
      document: '${raw['document'] ?? ''}',
    );
  }
}

class BusinessTrip {
  const BusinessTrip({
    required this.id,
    required this.destination,
    required this.purpose,
    this.organization = '',
    this.dateFrom,
    this.dateTo,
    this.days = 1,
    this.transport = 'other',
    this.advanceRequested = 0,
    this.advanceIssued,
    this.status = 'pending',
    this.note = '',
    this.employee,
    this.approver,
    this.accountant,
    this.expenses = const [],
    this.spent = 0,
    this.balance = 0,
    this.events = const [],
    this.isMine = false,
    this.canApprove = false,
    this.canAdvance = false,
    this.canEditReport = false,
    this.canCheck = false,
    this.canCancel = false,
  });

  final int id;
  final String destination;
  final String organization;
  final String purpose;
  final DateTime? dateFrom;
  final DateTime? dateTo;
  final int days;
  final String transport;
  final int advanceRequested;
  final int? advanceIssued;

  /// pending, approved, advanced, reported, closed, rejected, cancelled.
  final String status;

  /// Причина отказа или что исправить в отчёте.
  final String note;
  final ItPerson? employee;
  final ItPerson? approver;
  final ItPerson? accountant;
  final List<TripExpense> expenses;
  final int spent;

  /// Плюс — вернуть в кассу, минус — к выплате.
  final int balance;
  final List<ItEvent> events;
  final bool isMine;
  final bool canApprove;
  final bool canAdvance;
  final bool canEditReport;
  final bool canCheck;
  final bool canCancel;

  bool get isOpen =>
      const {'pending', 'approved', 'advanced', 'reported'}.contains(status);

  factory BusinessTrip.fromJson(Map<String, dynamic> json) {
    DateTime? day(Object? raw) => raw is String ? DateTime.tryParse(raw) : null;
    final events = json['events'];
    return BusinessTrip(
      id: _int(json['id']) ?? 0,
      destination: '${json['destination'] ?? ''}',
      organization: '${json['organization'] ?? ''}',
      purpose: '${json['purpose'] ?? ''}',
      dateFrom: day(json['date_from']),
      dateTo: day(json['date_to']),
      days: _int(json['days']) ?? 1,
      transport: '${json['transport'] ?? 'other'}',
      advanceRequested: _int(json['advance_requested']) ?? 0,
      advanceIssued: _int(json['advance_issued']),
      status: '${json['status'] ?? 'pending'}',
      note: '${json['note'] ?? ''}',
      employee: ItPerson.fromJson(json['employee']),
      approver: ItPerson.fromJson(json['approver']),
      accountant: ItPerson.fromJson(json['accountant']),
      expenses: ((json['expenses'] as List?) ?? const [])
          .map(TripExpense.fromJson)
          .whereType<TripExpense>()
          .toList(),
      spent: _int(json['spent']) ?? 0,
      balance: _int(json['balance']) ?? 0,
      events: events is List
          ? events
              .whereType<Map>()
              .map((e) => ItEvent.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
      isMine: json['is_mine'] == true,
      canApprove: json['can_approve'] == true,
      canAdvance: json['can_advance'] == true,
      canEditReport: json['can_edit_report'] == true,
      canCheck: json['can_check'] == true,
      canCancel: json['can_cancel'] == true,
    );
  }
}

class BusinessTripList {
  const BusinessTripList(
      {required this.items,
      this.approver = false,
      this.accountant = false,
      this.dailyAllowance = 0});

  final List<BusinessTrip> items;
  final bool approver;
  final bool accountant;

  /// Суточные за день, если бухгалтерия их задала; 0 — не подсказывать.
  final int dailyAllowance;

  factory BusinessTripList.fromJson(Map<String, dynamic> json) =>
      BusinessTripList(
        items: ((json['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => BusinessTrip.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        approver: json['approver'] == true,
        accountant: json['accountant'] == true,
        dailyAllowance: _int(json['daily_allowance']) ?? 0,
      );
}

class BusinessTripResult {
  const BusinessTripResult({this.item, this.error, this.problem});

  final BusinessTrip? item;
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

/// [scope]: null — мои, 'approve' — на согласование, 'accounting' — бухгалтерии.
Future<BusinessTripList> fetchBusinessTrips({String? scope}) async =>
    BusinessTripList.fromJson(
        await _get('/api/trips${scope == null ? '' : '?scope=$scope'}'));

Future<BusinessTrip> fetchBusinessTrip(int id) async {
  final body = await _get('/api/trips/$id');
  return BusinessTrip.fromJson(body['item'] as Map<String, dynamic>);
}

Future<BusinessTripResult> _post(String path, Map<String, Object?> body) async {
  try {
    final response = await http
        .post(_uri(path), headers: await authHeaders(), body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return const BusinessTripResult(problem: LoadProblem.denied);
    }
    Map<String, dynamic> parsed = const {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) parsed = decoded;
    } catch (_) {}
    if ((response.statusCode == 200 || response.statusCode == 201) &&
        parsed['item'] is Map) {
      return BusinessTripResult(
          item:
              BusinessTrip.fromJson(Map<String, dynamic>.from(parsed['item'])));
    }
    final error = parsed['error'];
    return BusinessTripResult(
        error: error is String ? error : null,
        problem: problemForStatus(response.statusCode));
  } catch (e) {
    return BusinessTripResult(problem: problemOf(e));
  }
}

String _isoDay(DateTime day) => '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

Future<BusinessTripResult> requestBusinessTrip({
  required String destination,
  required String purpose,
  required DateTime dateFrom,
  required DateTime dateTo,
  String organization = '',
  String transport = 'other',
  String advance = '',
}) =>
    _post('/api/trips', {
      'destination': destination,
      'purpose': purpose,
      'date_from': _isoDay(dateFrom),
      'date_to': _isoDay(dateTo),
      'transport': transport,
      if (organization.isNotEmpty) 'organization': organization,
      if (advance.isNotEmpty) 'advance': advance,
    });

/// approve, reject, advance, expense_add, expense_remove, report, accept,
/// send_back, cancel, comment.
Future<BusinessTripResult> businessTripAction(int id, String action,
        [Map<String, Object?> fields = const {}]) =>
    _post('/api/trips/$id', {'action': action, ...fields});
