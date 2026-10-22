import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/away_request.dart';
import 'package:se_mobile/screens/away_screen.dart';
import 'package:se_mobile/screens/directory_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';

import 'support/fake_server.dart';

/// «Меня нет на месте»: отметка в справочнике и экран отметки. Номера и
/// имена выдуманные.
void main() {
  String day(DateTime d) => d.toIso8601String().substring(0, 10);
  final today = DateTime.now();
  final away = {
    'reason': 'vacation',
    'start': day(today.subtract(const Duration(days: 2))),
    'end': day(today.add(const Duration(days: 5))),
    'active': true,
    'deputy': 'Заместов Зам',
    'deputy_extension': '150',
    'deputy_mobile': '',
    'note': 'По договорам — к юристам',
  };

  test('отметка с вышедшим сроком из кеша не показывается', () {
    final note = AwayNote.fromJson(away)!;
    expect(note.shownOn(today), isTrue);
    expect(note.shownOn(today.add(const Duration(days: 6))), isFalse);
    expect(AwayNote.fromJson({'reason': 'x'}), isNull);
    expect(AwayNote.fromJson({...away, 'reason': 'party'})!.reason, 'other');
  });

  test('надписи в обоих языках', () {
    final keys = LocaleString().keys;
    final ru = keys[Lang.ru]!.keys.where((k) => k.startsWith('away_')).toSet();
    final kk = keys[Lang.kk]!.keys.where((k) => k.startsWith('away_')).toSet();
    expect(kk, ru);
    for (final r in awayReasons) {
      expect(ru, contains('away_reason_$r'));
      expect(ru, contains('away_line_$r'));
    }
  });

  Future<void> pump(WidgetTester tester, FakeServer server, Widget home) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(Lang.initDates);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.pumpWidget(GetMaterialApp(
        translations: LocaleString(),
        locale: const Locale('ru'),
        home: home,
      ));
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
            () => Future.delayed(const Duration(milliseconds: 60)));
        await tester.pump();
      }
    }, server);
  }

  testWidgets('в справочнике видно, кого нет и кому звонить', (tester) async {
    final server = FakeServer.routed((method, url, body) => (
          200,
          jsonEncode({
            'message': 'Success',
            'entries': [
              {
                'department': 'Отдел',
                'name': 'Ушедший Тест',
                'position': 'Начальник',
                'extension': '110',
                'email': '',
                'mobile': '',
                'away': away,
              },
              {
                'department': 'Отдел',
                'name': 'Заместов Зам',
                'position': 'Заместитель',
                'extension': '150',
                'email': '',
                'mobile': '',
              },
            ],
          })
        ));
    await pump(tester, server, const DirectoryScreen());
    expect(find.byKey(const Key('directory_away_block')), findsOneWidget);
    final until =
        '${today.add(const Duration(days: 5)).day.toString().padLeft(2, '0')}.'
        '${today.add(const Duration(days: 5)).month.toString().padLeft(2, '0')}';
    expect(find.text('В отпуске до $until · замещает Заместов Зам'),
        findsOneWidget);
    expect(find.text('По договорам — к юристам'), findsOneWidget);
    // Номер заместителя — и под ним самим, и в отметке ушедшего.
    expect(find.text('150'), findsNWidgets(2));
  });

  testWidgets('экран: текущая отметка и «Я вернулся»', (tester) async {
    final server = FakeServer.routed((method, url, body) {
      if (method == 'DELETE') {
        return (200, jsonEncode({'message': 'Success', 'away': null}));
      }
      return (
        200,
        jsonEncode({'message': 'Success', 'away': away, 'can_manage': false})
      );
    });
    await pump(tester, server, const AwayScreen(names: ['Заместов Зам']));
    expect(find.byKey(const Key('away_current')), findsOneWidget);
    final deputy =
        tester.widget<TextField>(find.byKey(const Key('away_deputy')));
    expect(deputy.controller!.text, 'Заместов Зам');

    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.tap(find.byKey(const Key('away_clear')));
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
            () => Future.delayed(const Duration(milliseconds: 60)));
        await tester.pump();
      }
    }, server);
    expect(find.byKey(const Key('away_current')), findsNothing);
  });

  testWidgets('без дат не сохраняется', (tester) async {
    final server = FakeServer.routed((method, url, body) {
      if (method == 'PUT') return (500, 'не должно было уйти');
      return (200, jsonEncode({'message': 'Success', 'away': null}));
    });
    await pump(tester, server, const AwayScreen());
    await tester.tap(find.byKey(const Key('away_save')));
    await tester.pump();
    expect(find.text('Выберите даты'), findsOneWidget);
  });
}
