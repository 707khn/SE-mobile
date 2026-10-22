import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/data_correction_request.dart';
import 'package:se_mobile/screens/data_correction_detail_screen.dart';
import 'package:se_mobile/screens/data_corrections_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';

import 'support/fake_server.dart';

/// «Исправить мои данные»: форма с тем, что записано, и ответ кадров.
void main() {
  Map<String, dynamic> correction(int id, String status,
          {bool author = true, bool handle = false, String resolution = ''}) =>
      {
        'id': id,
        'kind': 'job',
        'current': 'Мастер',
        'requested': 'Старший мастер',
        'comment': 'Приказ от 01.10',
        'status': status,
        'resolution': resolution,
        'author': {'id': '0000000082', 'name': 'Мастер Тест'},
        'assignee': null,
        'created_at': '2030-01-15T05:00:00Z',
        'events': [
          {
            'action': 'created',
            'at': '2030-01-15T05:00:00Z',
            'actor': {'id': '0000000082', 'name': 'Мастер Тест'}
          }
        ],
        'is_author': author,
        'can_handle': handle,
      };

  test('разбор', () {
    final list = DataCorrectionList.fromJson({
      'staff': true,
      'waiting': 2,
      'profile': {'name': 'Мастер Тест', 'job': 'Мастер', 'department': 7},
      'items': [correction(1, 'new'), 'мусор']
    });
    expect(list.items.single.current, 'Мастер');
    expect(list.items.single.isOpen, isTrue);
    expect(list.profile, {'name': 'Мастер Тест', 'job': 'Мастер'});
    expect(list.waiting, 2);
  });

  test('надписи в обоих языках', () {
    final keys = LocaleString().keys;
    final ru = keys[Lang.ru]!.keys.where((k) => k.startsWith('dc_')).toSet();
    final kk = keys[Lang.kk]!.keys.where((k) => k.startsWith('dc_')).toSet();
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
    tester.view.physicalSize = const Size(900, 1800);
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

  testWidgets('форма показывает, что записано, и отправляет как правильно',
      (tester) async {
    final server = FakeServer.routed((method, url, body) => (
          201,
          jsonEncode({'message': 'Success', 'item': correction(3, 'new')})
        ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(
          tester,
          const DataCorrectionFormScreen(
              profile: {'name': 'Мастер Тест', 'job': 'Мастер'}));
      expect(find.text('Мастер Тест'), findsOneWidget);
      await tester.tap(find.byKey(const Key('dc_send')));
      await tester.pump();
      expect(find.text('Напишите, как правильно'), findsOneWidget);
      await tester.tap(find.byKey(const Key('dc_kind_job')));
      await tester.pump();
      expect(tester.widget<Text>(find.byKey(const Key('dc_current'))).data,
          'Мастер');
      await tester.tap(find.byKey(const Key('dc_kind_documents')));
      await tester.pump();
      expect(find.byKey(const Key('dc_current')), findsNothing);
      await tester.tap(find.byKey(const Key('dc_kind_job')));
      await tester.enterText(
          find.byKey(const Key('dc_requested')), 'Старший мастер');
      await tester.enterText(
          find.byKey(const Key('dc_comment_field')), 'Приказ от 01.10');
      await tester.tap(find.byKey(const Key('dc_send')));
      await settle(tester);
    }, server);
    expect(jsonDecode(server.requests.last), {
      'kind': 'job',
      'requested': 'Старший мастер',
      'comment': 'Приказ от 01.10',
    });
  });

  testWidgets('кадры отмечают «Исправлено»', (tester) async {
    final server = FakeServer.routed((method, url, body) => method == 'POST'
        ? (
            200,
            jsonEncode({
              'message': 'Success',
              'item': correction(5, 'done',
                  author: false, resolution: 'Исправлено в 1С')
            })
          )
        : (
            200,
            jsonEncode({
              'message': 'Success',
              'item': correction(5, 'in_work', author: false, handle: true)
            })
          ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const DataCorrectionDetailScreen(correctionId: 5));
      expect(find.text('Мастер Тест'), findsOneWidget);
      expect(find.byKey(const Key('dc_take')), findsNothing);
      expect(find.byKey(const Key('dc_cancel')), findsNothing);
      await tester.tap(find.byKey(const Key('dc_done')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('prompt_text')), 'Исправлено в 1С');
      await tester.pump();
      await tester.tap(find.byKey(const Key('prompt_ok')));
      await settle(tester);
      await tester.pumpAndSettle();
    }, server);
    expect(jsonDecode(server.requests.last),
        {'action': 'done', 'text': 'Исправлено в 1С'});
    expect(find.byKey(const Key('dc_resolution')), findsOneWidget);
    expect(find.byKey(const Key('dc_done')), findsNothing);
  });

  testWidgets('автор отзывает, пока не взяли', (tester) async {
    final server = FakeServer.routed((method, url, body) => method == 'POST'
        ? (
            200,
            jsonEncode(
                {'message': 'Success', 'item': correction(6, 'cancelled')})
          )
        : (
            200,
            jsonEncode({'message': 'Success', 'item': correction(6, 'new')})
          ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const DataCorrectionDetailScreen(correctionId: 6));
      expect(find.byKey(const Key('dc_done')), findsNothing);
      await tester.tap(find.byKey(const Key('dc_cancel')));
      await settle(tester);
    }, server);
    expect(jsonDecode(server.requests.last), {'action': 'cancel'});
    expect(find.text('Отозвана'), findsOneWidget);
  });

  testWidgets('у кадров — очередь с автором', (tester) async {
    final server = FakeServer.routed((method, url, body) => (
          200,
          jsonEncode({
            'message': 'Success',
            'staff': true,
            'waiting': 1,
            'profile': {'name': 'Кадровик'},
            'items': url.query.contains('queue')
                ? [correction(7, 'new', author: false, handle: true)]
                : [],
          })
        ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const DataCorrectionsScreen());
    }, server);
    expect(find.text('Очередь (1)'), findsOneWidget);
    expect(find.text('Мастер Тест'), findsOneWidget);
    expect(find.text('Старший мастер'), findsOneWidget);
  });
}
