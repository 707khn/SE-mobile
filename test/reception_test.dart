import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/reception_request.dart';
import 'package:se_mobile/screens/reception_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';

import 'support/fake_server.dart';

/// Запись на приём: свободные окна, запись с вопросом, ответ приёмной.
void main() {
  final director = {
    'id': '0000002183',
    'name': 'Директоров Арман',
    'job_title': 'Генеральный директор'
  };
  final deputy = {
    'id': '0000002184',
    'name': 'Замов Данияр',
    'job_title': 'Заместитель по экономике'
  };
  final master = {
    'id': '0000000082',
    'name': 'Мастеров Иван',
    'job_title': 'Мастер',
    'department': 'Основное производство (ОП)'
  };

  Map<String, dynamic> slot(int id, Map<String, dynamic> host, String at,
          {bool booked = false,
          bool mine = false,
          String? status,
          Map<String, dynamic>? employee}) =>
      {
        'id': id,
        'host': host,
        'starts_at': at,
        'minutes': 20,
        'booked': booked,
        'mine': mine,
        if (status != null) 'topic': 'Перевод на другой участок',
        if (status != null) 'status': status,
        if (employee != null) 'employee': employee,
      };

  test('разбор окна', () {
    final parsed =
        ReceptionSlot.fromJson(slot(1, director, '2030-03-06T14:00'))!;
    expect(parsed.startsAt, DateTime(2030, 3, 6, 14));
    expect(parsed.host?.name, 'Директоров Арман');
    expect(ReceptionSlot.fromJson({'id': 2}), isNull);
  });

  test('надписи в обоих языках', () {
    final keys = LocaleString().keys;
    final ru = keys[Lang.ru]!.keys.where((k) => k.startsWith('rc_')).toSet();
    final kk = keys[Lang.kk]!.keys.where((k) => k.startsWith('rc_')).toSet();
    expect(kk, ru);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester
          .runAsync(() => Future.delayed(const Duration(milliseconds: 60)));
      await tester.pump();
    }
  }

  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(900, 2200);
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

  testWidgets('сотрудник записывается к заместителю', (tester) async {
    final server = FakeServer.routed((method, url, body) {
      if (method == 'POST') return (200, jsonEncode({'message': 'Success'}));
      return (
        200,
        jsonEncode({
          'message': 'Success',
          'manager': false,
          'host': false,
          'hosts': [director, deputy],
          'bookings': [
            slot(9, director, '2030-03-05T10:00',
                booked: true, mine: true, status: 'confirmed'),
          ],
          'free': [
            slot(1, director, '2030-03-06T14:00'),
            slot(2, deputy, '2030-03-06T15:00'),
          ],
        })
      );
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const ReceptionScreen());
      expect(find.byType(TabBar), findsNothing);
      expect(
          find.text('Перевод на другой участок\nПодтверждено'), findsOneWidget);
      expect(find.byKey(const Key('rc_slot_2')), findsNothing);
      await tester.tap(find.byKey(const Key('rc_host_0000002184')));
      await tester.pump();
      expect(find.byKey(const Key('rc_slot_1')), findsNothing);
      expect(find.text('Среда, 6 марта, 15:00'), findsOneWidget);
      await tester.tap(find.byKey(const Key('rc_slot_2')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('prompt_text')), 'Премия участку');
      await tester.pump();
      await tester.tap(find.byKey(const Key('prompt_ok')));
      await settle(tester);
    }, server);
    expect(jsonDecode(server.requests.lastWhere((r) => r.isNotEmpty)),
        {'topic': 'Премия участку'});
    expect(find.textContaining('Вы записаны'), findsOneWidget);
  });

  testWidgets('приёмная отказывает с причиной', (tester) async {
    final urls = <Uri>[];
    final server = FakeServer.routed((method, url, body) {
      urls.add(url);
      if (method == 'POST') return (200, jsonEncode({'message': 'Success'}));
      if (url.path.endsWith('/desk')) {
        return (
          200,
          jsonEncode({
            'message': 'Success',
            'slots': [
              slot(4, director, '2030-03-06T14:00',
                  booked: true, status: 'requested', employee: master),
              slot(5, director, '2030-03-06T14:20'),
            ],
          })
        );
      }
      return (
        200,
        jsonEncode({
          'message': 'Success',
          'manager': true,
          'host': false,
          'hosts': [director, deputy],
          'bookings': [],
          'free': [],
        })
      );
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, ReceptionScreen(today: DateTime(2030, 3, 6)));
      expect(urls.last.queryParameters, {'date': '2030-03-06'});
      await tester.tap(find.text('Приёмная'));
      await tester.pumpAndSettle();
      expect(
          find.text('Основное производство (ОП)\n'
              'Перевод на другой участок\nЖдёт подтверждения'),
          findsOneWidget);
      await tester.tap(find.byKey(const Key('rc_desk_4')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('rc_decline')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('prompt_text')), 'Вопрос решит ПЭО');
      await tester.pump();
      await tester.tap(find.byKey(const Key('prompt_ok')));
      await settle(tester);
    }, server);
    expect(jsonDecode(server.requests.lastWhere((r) => r.isNotEmpty)),
        {'action': 'decline', 'reason': 'Вопрос решит ПЭО'});
    expect(urls.where((u) => u.path.endsWith('/slots/4')).length, 1);
  });
}
