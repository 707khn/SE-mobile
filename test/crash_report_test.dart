import 'package:flutter_test/flutter_test.dart';
import 'package:se_mobile/utils/crash_report.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ошибки уходят на сервер сами — но не по кругу, не с личным в тексте и не
/// теряются, когда связи нет.
void main() {
  late List<Map<String, dynamic>> sent;
  late int? answer;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    CrashReport.resetForTest();
    CrashReport.enabled = true;
    sent = [];
    answer = 202;
    CrashReport.sender = (report) async {
      sent.add(report);
      return answer;
    };
  });

  test('ошибка уходит на сервер с версией и номером установки', () async {
    await CrashReport.report(error: 'Bad state: x', stack: '#0 f', where: 'w');
    expect(sent, hasLength(1));
    expect(sent.single['error'], 'Bad state: x');
    expect(sent.single['version'], isNotEmpty);
    expect((sent.single['install'] as String).length, 16);
  });

  test('номер установки один и тот же', () async {
    await CrashReport.report(error: 'a');
    await CrashReport.report(error: 'b');
    expect(sent[0]['install'], sent[1]['install']);
  });

  test('одна и та же ошибка за запуск уходит один раз', () async {
    for (var i = 0; i < 50; i++) {
      await CrashReport.report(error: 'RenderFlex overflowed');
    }
    expect(sent, hasLength(1));
  });

  test('за запуск — не больше десяти', () async {
    for (var i = 0; i < 30; i++) {
      await CrashReport.report(error: 'ошибка $i');
    }
    expect(sent, hasLength(10));
  });

  test('без связи отчёт ждёт и уходит потом', () async {
    answer = null;
    await CrashReport.report(error: 'offline');
    expect(sent, hasLength(1));
    sent.clear();
    answer = 202;
    await CrashReport.flush();
    expect(sent, hasLength(1));
    sent.clear();
    await CrashReport.flush();
    expect(sent, isEmpty, reason: 'отправленное не повторяется');
  });

  test('отказ по форме не повторяется', () async {
    answer = 400;
    await CrashReport.report(error: 'x');
    sent.clear();
    await CrashReport.flush();
    expect(sent, isEmpty);
  });

  test('в отладочной сборке ничего не уходит', () async {
    CrashReport.enabled = false;
    await CrashReport.report(error: 'x');
    expect(sent, isEmpty);
  });

  test('личное вычищается', () {
    final text = CrashReport.scrub(
        'ИИН 870101300123, user@se.kz, +7 (777) 123-45-67, Bearer abc.def '
        'at file.dart:120:7');
    expect(text, isNot(contains('870101300123')));
    expect(text, isNot(contains('user@se.kz')));
    expect(text, isNot(contains('123-45-67')));
    expect(text, isNot(contains('abc.def')));
    expect(text, contains('file.dart:120:7'));
  });
}
