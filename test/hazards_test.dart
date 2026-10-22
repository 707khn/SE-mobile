import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/hazard_request.dart';
import 'package:se_mobile/screens/hazard_detail_screen.dart';
import 'package:se_mobile/screens/hazard_form_screen.dart';
import 'package:se_mobile/screens/hazards_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';

import 'support/fake_server.dart';

/// Сообщить об опасности: анонимный ключ на телефоне, очередь БиОТ.
void main() {
  Map<String, dynamic> hazard(int id, String status,
          {bool anonymous = false, bool canAct = false, String outcome = ''}) =>
      {
        'id': id,
        'category': 'spill',
        'place': 'Цех 2, у пресса',
        'text': 'Масло на полу',
        'urgent': true,
        'status': status,
        'anonymous': anonymous,
        'author': anonymous ? null : {'id': '0000002107', 'name': 'Автор Тест'},
        'assignee': null,
        'outcome': outcome,
        'created_at': '2030-01-15T05:00:00Z',
        'events': [
          {'action': 'created', 'at': '2030-01-15T05:00:00Z', 'actor': null}
        ],
        'is_author': !anonymous,
        'can_act': canAct,
      };

  test('разбор', () {
    final h = Hazard.fromJson(hazard(1, 'new', anonymous: true));
    expect(h.anonymous, isTrue);
    expect(h.author, isNull);
    expect(h.isOpen, isTrue);
    final list = HazardList.fromJson({
      'staff': true,
      'new': 2,
      'items': [hazard(1, 'new'), 'x']
    });
    expect(list.items.single.id, 1);
    expect(list.fresh, 2);
  });

  test('надписи в обоих языках', () {
    final keys = LocaleString().keys;
    final ru = keys[Lang.ru]!.keys.where((k) => k.startsWith('hz_')).toSet();
    final kk = keys[Lang.kk]!.keys.where((k) => k.startsWith('hz_')).toSet();
    expect(kk, ru);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester
          .runAsync(() => Future.delayed(const Duration(milliseconds: 60)));
      await tester.pump();
    }
  }

  Future<void> pump(WidgetTester tester, Widget home,
      {Map<String, Object> prefs = const {}}) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(Lang.initDates);
    SharedPreferences.setMockInitialValues(prefs);
    FlutterSecureStorage.setMockInitialValues({});
    await tester.pumpWidget(GetMaterialApp(
      translations: LocaleString(),
      locale: const Locale('ru'),
      home: home,
    ));
    await settle(tester);
  }

  testWidgets('анонимное сообщение: ключ остаётся на телефоне', (tester) async {
    final server = FakeServer.routed((method, url, body) => (
          201,
          jsonEncode({
            'message': 'Success',
            'item': hazard(5, 'new', anonymous: true),
            'track': 'ключ-5'
          })
        ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const HazardFormScreen());
      await tester.tap(find.byKey(const Key('hz_send')));
      await tester.pump();
      expect(find.text('Выберите, что случилось'), findsOneWidget);
      await tester.tap(find.byKey(const Key('hz_cat_electrical')));
      await tester.enterText(find.byKey(const Key('hz_place')), 'Склад №2');
      await tester.enterText(
          find.byKey(const Key('hz_text')), 'Открытый щиток');
      await tester.tap(find.byKey(const Key('hz_anonymous')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('hz_send')));
      await settle(tester);
    }, server);
    expect(jsonDecode(server.requests.single), {
      'category': 'electrical',
      'place': 'Склад №2',
      'text': 'Открытый щиток',
      'anonymous': true,
    });
    final saved = await tester.runAsync(savedHazardTracks);
    expect(saved, ['ключ-5']);
  });

  testWidgets('в моих — и свои, и анонимные с этого телефона', (tester) async {
    final server = FakeServer.routed((method, url, body) {
      if (url.path.endsWith('/track')) {
        expect(jsonDecode(body), {
          'tokens': ['ключ-5']
        });
        return (
          200,
          jsonEncode({
            'message': 'Success',
            'items': [
              hazard(5, 'resolved',
                  anonymous: true, outcome: 'Щиток закрыли на замок')
            ]
          })
        );
      }
      return (
        200,
        jsonEncode({
          'message': 'Success',
          'staff': false,
          'items': [hazard(4, 'new')]
        })
      );
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const HazardsScreen(), prefs: {
        'hazard_tracks': ['ключ-5']
      });
      expect(find.text('Анонимно'), findsNothing);
      expect(find.textContaining('Анонимно'), findsOneWidget);
      expect(find.text('Устранено'), findsOneWidget);
      expect(find.text('Новое'), findsOneWidget);
      await tester.tap(find.text('Устранено'));
      await settle(tester);
      await tester.pumpAndSettle();
    }, server);
    expect(find.byType(HazardDetailScreen), findsOneWidget);
    expect(find.text('БиОТ: Щиток закрыли на замок'), findsOneWidget);
  });

  testWidgets('инженер БиОТ закрывает с отметкой, что сделано', (tester) async {
    final server = FakeServer.routed((method, url, body) => method == 'POST'
        ? (
            200,
            jsonEncode({
              'message': 'Success',
              'item': hazard(4, 'resolved', outcome: 'Убрали, поставили поддон')
            })
          )
        : (
            200,
            jsonEncode({
              'message': 'Success',
              'item': hazard(4, 'in_work', canAct: true)
            })
          ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const HazardDetailScreen(hazardId: 4));
      expect(find.byKey(const Key('hz_take')), findsNothing);
      await tester.tap(find.byKey(const Key('hz_resolve')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('prompt_text')), 'Убрали, поставили поддон');
      await tester.pump();
      await tester.tap(find.byKey(const Key('prompt_ok')));
      await settle(tester);
      await tester.pumpAndSettle();
    }, server);
    expect(jsonDecode(server.requests.last),
        {'action': 'resolve', 'comment': 'Убрали, поставили поддон'});
    expect(find.text('БиОТ: Убрали, поставили поддон'), findsOneWidget);
    expect(find.byKey(const Key('hz_resolve')), findsNothing);
  });
}
