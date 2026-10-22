import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/material_pass_request.dart';
import 'package:se_mobile/screens/material_pass_detail_screen.dart';
import 'package:se_mobile/screens/material_pass_form_screen.dart';
import 'package:se_mobile/screens/material_passes_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';

import 'support/fake_server.dart';

/// Материальный пропуск: разбор, вкладки по ролям, форма, КПП с кодом.
void main() {
  String iso(DateTime d) => d.toIso8601String().substring(0, 10);
  final today = DateTime.now();

  Map<String, dynamic> item(int id, String status,
          {bool expired = false,
          bool canRelease = false,
          bool canApprove = false,
          bool isAuthor = false,
          String? code}) =>
      {
        'id': id,
        'purpose': 'В ремонт ТОО «Сервис»',
        'carrier': 'Водитель Тестов',
        'vehicle': '123ABC02',
        'exit_date': iso(today),
        'status': status,
        'expired': expired,
        if (code != null) 'code': code,
        'author': {'id': '0000002152', 'name': 'Кладовщик Тест'},
        'approver': null,
        'guard': null,
        'reason': '',
        'created_at': '2026-10-22T05:00:00+00:00',
        'lines': [
          {'name': 'Насос К-80', 'quantity': 1, 'unit': 'шт'},
          {'name': 'Кабель', 'quantity': 25.5, 'unit': 'м'},
        ],
        'events': [],
        'is_author': isAuthor,
        'can_approve': canApprove,
        'can_release': canRelease,
      };

  test('разбор и просроченный статус', () {
    final p = MaterialPass.fromJson(item(3, 'approved', code: '0427'));
    expect(p.code, '0427');
    expect(p.lines.last.amount, '25,5 м');
    expect(p.isOpen, isTrue);
    expect(p.shownStatus, 'approved');
    final late = MaterialPass.fromJson(item(4, 'approved', expired: true));
    expect(late.shownStatus, 'expired');
    expect(late.isOpen, isFalse);
    expect(late.code, isNull);
  });

  test('надписи в обоих языках', () {
    final keys = LocaleString().keys;
    final ru = keys[Lang.ru]!.keys.where((k) => k.startsWith('pass_')).toSet();
    final kk = keys[Lang.kk]!.keys.where((k) => k.startsWith('pass_')).toSet();
    expect(kk, ru);
    for (final s in [
      'pending',
      'approved',
      'rejected',
      'released',
      'held',
      'cancelled',
      'expired'
    ]) {
      expect(ru, contains('pass_status_$s'));
    }
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
          () => Future.delayed(const Duration(milliseconds: 60)));
      await tester.pump();
    }
  }

  Future<void> pump(WidgetTester tester, FakeServer server, Widget home) async {
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(Lang.initDates);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await tester.pumpWidget(GetMaterialApp(
      translations: LocaleString(),
      locale: const Locale('ru'),
      home: home,
    ));
    await settle(tester);
  }

  testWidgets('охрана: вкладка КПП первой, обычному — без вкладок',
      (tester) async {
    final server = FakeServer.routed((method, url, body) {
      if (url.query == 'scope=gate') {
        return (
          200,
          jsonEncode({
            'roles': {'guard': true},
            'items': [item(7, 'approved', canRelease: true)]
          })
        );
      }
      return (
        200,
        jsonEncode({
          'roles': {'guard': true, 'approver': false},
          'items': []
        })
      );
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, server, const MaterialPassesScreen());
    }, server);
    expect(find.text('КПП сегодня'), findsOneWidget);
    expect(find.text('№7 · Водитель Тестов'), findsOneWidget);
    expect(find.byKey(const Key('pass_find')), findsOneWidget);
  });

  testWidgets('форма: завтра и позиции', (tester) async {
    final server = FakeServer.routed((method, url, body) => (
          201,
          jsonEncode({'message': 'Success', 'item': item(9, 'pending')})
        ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, server, const MaterialPassFormScreen());
      await tester.enterText(
          find.byKey(const Key('pass_purpose')), 'В ремонт');
      await tester.tap(find.byKey(const Key('pass_send')));
      await tester.pump();
      expect(find.text('Напишите, кто вывозит'), findsOneWidget);

      await tester.enterText(
          find.byKey(const Key('pass_carrier')), 'Водитель Тестов');
      await tester.enterText(find.byKey(const Key('pass_vehicle')), '123ABC02');
      await tester.tap(find.byKey(const Key('pass_tomorrow')));
      await tester.enterText(
          find.byKey(const Key('pass_line_name_0')), 'Насос К-80');
      await tester.enterText(find.byKey(const Key('pass_line_qty_0')), '1');
      await tester.pump();
      await tester.tap(find.byKey(const Key('pass_send')));
      await settle(tester);
    }, server);
    final sent = jsonDecode(server.requests.single) as Map<String, dynamic>;
    final tomorrow = DateTime(today.year, today.month, today.day + 1);
    expect(sent, {
      'purpose': 'В ремонт',
      'carrier': 'Водитель Тестов',
      'vehicle': '123ABC02',
      'exit_date': iso(tomorrow),
      'lines': [
        {'name': 'Насос К-80', 'quantity': 1.0, 'unit': 'шт'}
      ],
    });
  });

  testWidgets('КПП: код для сверки и «Не выпускать» с причиной',
      (tester) async {
    final server = FakeServer.routed((method, url, body) {
      if (method == 'POST') {
        return (
          200,
          jsonEncode({
            'message': 'Success',
            'item': {...item(7, 'held'), 'reason': 'Насосов два'}
          })
        );
      }
      return (
        200,
        jsonEncode({
          'message': 'Success',
          'item': item(7, 'approved', canRelease: true, code: '0427')
        })
      );
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, server, const MaterialPassDetailScreen(passId: 7));
      expect(find.text('0427'), findsOneWidget);
      expect(find.text('Спросите у водителя код: должен быть 0427'),
          findsOneWidget);
      expect(find.byKey(const Key('pass_approve')), findsNothing);

      await tester.tap(find.byKey(const Key('pass_hold')));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<TextButton>(find.byKey(const Key('prompt_ok')))
              .onPressed,
          isNull);
      await tester.enterText(find.byKey(const Key('prompt_text')), 'Насосов два');
      await tester.pump();
      await tester.tap(find.byKey(const Key('prompt_ok')));
      await settle(tester);
    }, server);
    final sent = jsonDecode(server.requests.last) as Map<String, dynamic>;
    expect(sent, {'action': 'hold', 'comment': 'Насосов два'});
    expect(find.text('Не выпущено'), findsOneWidget);
    expect(find.text('Причина: Насосов два'), findsOneWidget);
    // Задержанный — кода на экране больше нет.
    expect(find.byKey(const Key('pass_code')), findsNothing);
  });
}
