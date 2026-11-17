import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../utils/secure_storage_helper.dart';
import '../utils/variables.dart';
import '../utils/api.dart';
import '../utils/offline_cache.dart';

enum PayslipErrorKind { timeout, network, notFound }

class PayslipException implements Exception {
  final PayslipErrorKind kind;
  const PayslipException(this.kind);
}

class PayslipItem {
  final String name;
  final double amount;
  const PayslipItem({required this.name, required this.amount});
}

class PayslipPaidItem {
  final String paymentType;
  final String period;
  final String document;
  final String date;
  final double amount;
  const PayslipPaidItem({
    required this.paymentType,
    required this.period,
    required this.document,
    required this.date,
    required this.amount,
  });
}

class PayslipData {
  final String period;
  final String employee;
  final String position;
  final String department;
  final List<PayslipItem> accruals;
  final List<PayslipItem> deductions;
  final List<PayslipPaidItem> paid;
  final List<PayslipItem> benefits;
  final List<PayslipItem> reference;
  final double totalAccruals;
  final double totalDeductions;
  final double totalPaid;
  final double netPay;
  final double debtStart;
  final double debtEnd;

  /// Когда листок был получен с сервера. У свежего пусто, у показанного
  /// без связи — время последнего удачного запроса.
  final DateTime? cachedAt;

  const PayslipData({
    required this.period,
    required this.employee,
    required this.position,
    required this.department,
    required this.accruals,
    required this.deductions,
    required this.paid,
    required this.benefits,
    required this.reference,
    required this.totalAccruals,
    required this.totalDeductions,
    required this.totalPaid,
    required this.netPay,
    required this.debtStart,
    required this.debtEnd,
    this.cachedAt,
  });

  /// Есть ли у листка взаиморасчёты: долги на начало и конец, выплаты.
  /// У листков из старой выгрузки XML их может не быть — тогда «к выплате»
  /// остаётся «начислено минус удержано».
  bool get hasSettlement => debtStart != 0 || debtEnd != 0 || totalPaid != 0;

  /// Сколько предприятие должно работнику на конец месяца — как в 1С
  /// («Долг за организацией на конец месяца»). «Начислено минус удержано»
  /// с ним не совпадает, как только в месяце были выплаты: аванс, деньги
  /// из кассы. Отрицательное — должен работник.
  double get toPay => hasSettlement ? debtEnd : netPay;
}

// Табельный номер: сохранённый, а если его нет — с сервера по пропуску.
//
// Сохранённого номера может не быть после обновления с очень старой
// сборки. Раньше здесь входили заново сохранённым паролем — теперь хватает
// пропуска, и пароль на телефоне больше не нужен.
Future<String?> _resolveEmployeeId() async {
  final storage = SecureStorageHelper.instance;
  final cached = await storage.getEmployeeId();
  if (cached != null && cached.isNotEmpty) return cached;
  return employeeIdFromServer();
}

PayslipItem _toItem(dynamic e) {
  final m = e as Map;
  return PayslipItem(
    name: m['name'] as String,
    amount: (m['amount'] as num).toDouble(),
  );
}

/// Листок файлом Excel в вёрстке 1С — для кнопки «Поделиться».
///
/// Null — файла получить не удалось (нет связи, нет листка): тогда экран
/// делится текстом. Повторов, как у самого листка, здесь нет — человек
/// ждёт с открытым экраном, и минута ожидания хуже текста сразу.
Future<Uint8List?> downloadPayslipXlsx(String month, String year,
    {String? employeeId}) async {
  final id = (employeeId != null && employeeId.isNotEmpty)
      ? employeeId
      : await _resolveEmployeeId();
  if (id == null || id.isEmpty) return null;
  try {
    final response = await http
        .post(
          Uri.parse('${AppValues.baseUrl}/payslip/xlsx'),
          headers: await authHeaders(),
          body: jsonEncode({'key_suffix': id, 'month': month, 'year': year}),
        )
        .timeout(const Duration(seconds: 30));
    if (await handledUnauthorized(response)) return null;
    final type = response.headers['content-type'] ?? '';
    // Старый сервер, где этого адреса ещё нет, ответит страницей ошибки, а
    // не файлом — её отправлять нельзя.
    if (response.statusCode != 200 || !type.contains('spreadsheetml')) {
      return null;
    }
    return response.bodyBytes;
  } catch (_) {
    return null;
  }
}

/// [employeeId] overrides the signed-in user — used by the admin panel to read
/// somebody else's payslip.
Future<PayslipData> fetchPayslip(String month, String year,
    {String? employeeId}) async {
  // Копию держим только своих листков. Раньше она лежала под ключом
  // «год_месяц» без табельного номера, и листок сотрудника, открытый
  // руководителем, ложился на место его собственного: без связи руководитель
  // открывал свой листок — и видел чужую зарплату. Да и чужим листкам на
  // телефоне руководителя лежать незачем.
  final own = employeeId == null || employeeId.isEmpty;
  final id = own ? await _resolveEmployeeId() : employeeId;
  if (id == null || id.isEmpty) {
    throw const PayslipException(PayslipErrorKind.notFound);
  }
  final cacheKey = own ? 'payslip_${id}_${year}_$month' : null;

  final http.Response response;
  try {
    // Повторов больше нет. Они были для бесплатного хостинга, который
    // засыпал и просыпался минуту; теперь сервер свой и не спит, а без связи
    // человек ждал три повтора по двадцать секунд, прежде чем увидеть
    // сохранённый листок.
    response = await http
        .post(
          Uri.parse('${AppValues.baseUrl}/payslip'),
          headers: await authHeaders(),
          body: jsonEncode({'key_suffix': id, 'month': month, 'year': year}),
        )
        .timeout(const Duration(seconds: 20));
  } on TimeoutException {
    return _savedOr(cacheKey, PayslipErrorKind.timeout);
  } catch (_) {
    return _savedOr(cacheKey, PayslipErrorKind.network);
  }

  if (await handledUnauthorized(response)) {
    throw const PayslipException(PayslipErrorKind.notFound);
  }
  // Ошибка сервера — тоже повод показать сохранённое: когда служба лежит,
  // nginx отвечает 502, а листок за прошлый месяц от этого не изменился.
  if (response.statusCode != 200) {
    return _savedOr(cacheKey, PayslipErrorKind.network);
  }

  // 200, а внутри не JSON: так отвечает страница входа в гостевой Wi-Fi.
  // Раньше разбор здесь падал, и вместо сохранённого листка человек видел
  // «ошибку сети» — хотя листок за прошлый месяц лежал у него в телефоне.
  final Object? decoded;
  try {
    decoded = jsonDecode(response.body);
  } on FormatException {
    return _savedOr(cacheKey, PayslipErrorKind.network);
  }
  if (decoded is! Map<String, dynamic>) {
    return _savedOr(cacheKey, PayslipErrorKind.network);
  }
  final body = decoded;
  if (body['message'] != 'Success') {
    throw const PayslipException(PayslipErrorKind.notFound);
  }

  if (cacheKey != null) {
    await OfflineCache.save(cacheKey, body, private: true);
    // Год листков с запасом: дальше их и с сервером почти не открывают, а
    // защищённое хранилище читается целиком.
    await OfflineCache.trim('payslip_${id}_', keep: 13, private: true);
  }
  return _payslipFrom(body);
}

/// Сохранённый листок или ошибка, если его нет (или он чужой — тогда
/// копии не бывает вовсе).
Future<PayslipData> _savedOr(String? cacheKey, PayslipErrorKind kind) async {
  final saved = cacheKey == null ? null : await _cachedPayslip(cacheKey);
  if (saved != null) return saved;
  throw PayslipException(kind);
}

/// Собирает листок из ответа сервера — своего или сохранённого ранее.
PayslipData _payslipFrom(Map<String, dynamic> body) {
  final p = body['payslip'] as Map<String, dynamic>;

  return PayslipData(

    cachedAt: cachedAt(body),
    period: p['period'] as String,
    employee: p['employee'] as String,
    position: (p['position'] as String?) ?? '',
    department: (p['department'] as String?) ?? '',
    accruals: (p['accruals'] as List).map(_toItem).toList(),
    deductions: (p['deductions'] as List).map(_toItem).toList(),
    paid: ((p['paid'] ?? []) as List).map((e) {
      final m = e as Map;
      return PayslipPaidItem(
        paymentType: (m['payment_type'] as String?) ?? '',
        period: (m['period'] as String?) ?? '',
        document: (m['document'] as String?) ?? '',
        date: (m['date'] as String?) ?? '',
        amount: (m['amount'] as num).toDouble(),
      );
    }).toList(),
    benefits: ((p['benefits'] ?? []) as List).map(_toItem).toList(),
    reference: ((p['reference'] ?? []) as List).map(_toItem).toList(),
    totalAccruals: (p['total_accruals'] as num).toDouble(),
    totalDeductions: (p['total_deductions'] as num).toDouble(),
    totalPaid: ((p['total_paid'] ?? 0) as num).toDouble(),
    netPay: (p['net_pay'] as num).toDouble(),
    debtStart: ((p['debt_start'] ?? 0) as num).toDouble(),
    debtEnd: ((p['debt_end'] ?? 0) as num).toDouble(),
  );
}

/// Листок, полученный в прошлый раз. Свой листок человек открывает и в
/// дороге, и в цеху, где связи нет, — пусть открывается.
Future<PayslipData?> _cachedPayslip(String cacheKey) async {
  final saved = await OfflineCache.read(cacheKey, private: true);
  if (saved == null || saved['payslip'] is! Map) return null;
  try {
    return _payslipFrom(saved);
  } catch (_) {
    return null;
  }
}


/// Месяцы, за которые у человека есть расчётный лист, свежие первыми.
///
/// Экран открывался на прошлом месяце и был пуст: листки приносят с
/// задержкой, и «прошлый месяц» почти никогда не тот, что есть в базе.
/// Пустой список — значит листков нет вовсе; null — сервер не ответил, и
/// экран ведёт себя как раньше.
Future<List<DateTime>?> fetchPayslipPeriods({String? employeeId}) async {
  final own = employeeId == null || employeeId.isEmpty;
  final id = own ? await _resolveEmployeeId() : employeeId;
  if (id == null || id.isEmpty) return null;
  // Как и листки: копия — только своя.
  Future<List<DateTime>?> saved() async => own ? _cachedPeriods(id) : null;
  try {
    final response = await http
        .post(
          Uri.parse('${AppValues.baseUrl}/payslip/periods'),
          headers: await authHeaders(),
          body: jsonEncode({'key_suffix': id}),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) return await saved();
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (body['message'] != 'Success' || body['periods'] is! List) {
      return await saved();
    }
    if (own) await OfflineCache.save('payslip_periods_$id', body);
    return _periodsFrom(body);
  } catch (_) {
    // В цеху связи нет, а список месяцев меняется раз в месяц: сохранённый
    // подойдёт.
    return saved();
  }
}

List<DateTime> _periodsFrom(Map<String, dynamic> body) {
  final out = <DateTime>[];
  for (final item in (body['periods'] as List)) {
    if (item is! Map) continue;
    final year = (item['year'] as num?)?.toInt();
    final month = (item['month'] as num?)?.toInt();
    if (year == null || month == null || month < 1 || month > 12) continue;
    out.add(DateTime(year, month));
  }
  out.sort((a, b) => b.compareTo(a));
  return out;
}

Future<List<DateTime>?> _cachedPeriods(String employeeId) async {
  final saved = await OfflineCache.read('payslip_periods_$employeeId');
  if (saved == null || saved['periods'] is! List) return null;
  try {
    return _periodsFrom(saved);
  } catch (_) {
    return null;
  }
}
