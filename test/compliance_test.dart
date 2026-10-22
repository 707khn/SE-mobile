import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/compliance_request.dart';
import 'package:se_mobile/screens/compliance_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';

import 'support/fake_server.dart';

/// Горячая линия: анонимное сообщение с ключом на телефоне, офицер отвечает.
void main() {
  Map<String, dynamic> report(int id,
          {bool anonymous = true,
          String status = 'new',
          List<Map<String, dynamic>> messages = const [],
          bool handle = false,
          int? trackIndex}) =>
      {
        'id': id,
        'kind': 'corruption',
        'text': 'Поставщик предлагает откат за подпись акта',
        'status': status,
        'resolution': '',
        'anonymous': anonymous,
        'created_at': '2030-01-15T00:00:00Z',
        'messages': messages,
        'is_mine': !handle,
        'can_reply': status != 'closed',
        'can_handle': handle,
        if (!anonymous) 'author': {'id': '0000000082', 'name': 'Мастеров Иван'},
        if (trackIndex != null) 'track_index': trackIndex,
      };

  test('надписи в обоих языках', () {
    final keys = LocaleString().keys;
    final ru = keys[Lang.ru]!.keys.where((k) => k.startsWith('cp_')).toSet();
    final kk = keys[Lang.kk]!.keys.where((k) => k.startsWith('cp_')).toSet();
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
    await tester.pumpWidget(GetMaterialApp(
      translations: LocaleString(),
      locale: const Locale('ru'),
      home: home,
    ));
    await settle(tester);
  }

  testWidgets('анонимное сообщение: ключ остаётся на телефоне', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final paths = <String>[];
    final server = FakeServer.routed((method, url, body) {
      paths.add('$method ${url.path}');
      if (method == 'POST' && url.path == '/api/compliance') {
        return (
          201,
          jsonEncode({
            'message': 'Success',
            'item': report(7),
            'track': 'секретный-ключ'
          })
        );
      }
      if (url.path.endsWith('/track')) {
        return (
          200,
          jsonEncode({
            'message': 'Success',
            'items': [
              report(7, status: 'review', trackIndex: 0, messages: [
                {'from_officer': true, 'text': 'Какой поставщик?'}
              ])
            ]
          })
        );
      }
      if (method == 'POST') {
        return (
          200,
          jsonEncode(
              {'message': 'Success', 'item': report(7, status: 'review')})
        );
      }
      return (
        200,
        jsonEncode({'message': 'Success', 'officer': false, 'mine': []})
      );
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const ComplianceScreen());
      expect(find.text('Вы ещё ничего не отправляли.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('cp_new')));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<SwitchListTile>(find.byKey(const Key('cp_anonymous')))
              .value,
          isTrue);
      await tester.enterText(find.byKey(const Key('cp_text')),
          'Поставщик предлагает откат за подпись акта');
      await tester.tap(find.byKey(const Key('cp_send')));
      await settle(tester);
      await tester.pumpAndSettle();
      await settle(tester);
      expect(jsonDecode(server.requests.firstWhere((r) => r.isNotEmpty)), {
        'kind': 'corruption',
        'text': 'Поставщик предлагает откат за подпись акта',
        'anonymous': true,
      });
      expect(paths, contains('POST /api/compliance/track'));
      expect(find.text('На проверке'), findsOneWidget);

      await tester.tap(find.byKey(const Key('cp_item_7')));
      await tester.pumpAndSettle();
      expect(find.text('Какой поставщик?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('cp_reply')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('field_text')), 'ТОО «Ромашка»');
      await tester.pump();
      await tester.tap(find.byKey(const Key('fields_ok')));
      await settle(tester);
    }, server);
    expect(jsonDecode(server.requests.lastWhere((r) => r.isNotEmpty)), {
      'action': 'message',
      'text': 'ТОО «Ромашка»',
      'track': 'секретный-ключ',
    });
  });

  testWidgets('офицер видит автора и закрывает с итогом', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final server = FakeServer.routed((method, url, body) => method == 'POST'
        ? (
            200,
            jsonEncode({
              'message': 'Success',
              'item': {
                ...report(3, anonymous: false, status: 'closed'),
                'resolution': 'Передано руководству',
              }
            })
          )
        : (
            200,
            jsonEncode({
              'message': 'Success',
              'officer': true,
              'mine': [],
              'queue': [report(3, anonymous: false, handle: true)],
            })
          ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const ComplianceScreen());
      expect(find.text('Сообщения'), findsOneWidget);
      await tester.tap(find.byKey(const Key('cp_item_3')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Мастеров Иван'), findsOneWidget);
      await tester.tap(find.byKey(const Key('cp_close')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('field_text')), 'Передано руководству');
      await tester.pump();
      await tester.tap(find.byKey(const Key('fields_ok')));
      await settle(tester);
    }, server);
    expect(jsonDecode(server.requests.lastWhere((r) => r.isNotEmpty)),
        {'action': 'close', 'text': 'Передано руководству'});
    expect(find.byKey(const Key('cp_resolution')), findsOneWidget);
  });
}
