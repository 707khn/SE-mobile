import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/tech_request.dart';
import 'package:se_mobile/screens/it_request_form_screen.dart';
import 'package:se_mobile/screens/tech_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';

import 'support/fake_server.dart';

/// Техника за сотрудником и плановые отключения.
void main() {
  const op = 'Основное производство (ОП)';

  Map<String, dynamic> outage(int id,
          {String state = 'planned',
          bool mine = true,
          List<String> departments = const [op]}) =>
      {
        'id': id,
        'kind': 'power',
        'note': 'Замена трансформатора',
        'starts_at': '2030-03-09T09:00',
        'ends_at': '2030-03-09T13:00',
        'departments': departments,
        'mine': mine,
        'state': state,
      };

  Map<String, dynamic> asset(int id, {Map<String, dynamic>? holder}) => {
        'id': id,
        'kind': 'laptop',
        'model': 'HP ProBook 450',
        'inventory_no': 'ИТ-0042',
        'serial': '',
        'room': '214',
        'note': '',
        if (holder != null) 'holder': holder,
      };

  final master = {
    'id': '0000000082',
    'name': 'Мастеров Иван',
    'job_title': 'Мастер'
  };

  test('время отключения', () {
    Get.locale = const Locale('ru');
    Get.addTranslations(LocaleString().keys);
    final same = Outage.fromJson(outage(1))!;
    expect(outageWhen(same), '09.03, 09:00–13:00');
    final night =
        Outage.fromJson({...outage(2), 'ends_at': '2030-03-10T08:00'})!;
    expect(outageWhen(night), '09.03 09:00 — 10.03 08:00');
    expect(Outage.fromJson({'id': 3, 'starts_at': 'вчера'}), isNull);
  });

  test('надписи в обоих языках', () {
    final keys = LocaleString().keys;
    final ru = keys[Lang.ru]!.keys.where((k) => k.startsWith('ta_')).toSet();
    final kk = keys[Lang.kk]!.keys.where((k) => k.startsWith('ta_')).toSet();
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

  testWidgets('сотрудник: отключения и своя техника', (tester) async {
    final server = FakeServer.routed((method, url, body) {
      if (url.path.endsWith('/mine')) {
        return (
          200,
          jsonEncode({
            'message': 'Success',
            'staff': false,
            'items': [asset(5)]
          })
        );
      }
      return (
        200,
        jsonEncode({
          'message': 'Success',
          'staff': false,
          'items': [
            outage(1),
            outage(2, mine: false, departments: const [], state: 'cancelled'),
          ],
        })
      );
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const TechScreen());
      expect(find.text('Учёт'), findsNothing);
      expect(find.byKey(const Key('ta_announce')), findsNothing);
      expect(
          find.text('Электроэнергия · 09.03, 09:00–13:00'), findsNWidgets(2));
      expect(find.text('Замена трансформатора\n$op\nКасается вас'),
          findsOneWidget);
      expect(
          find.text('Замена трансформатора\nВсё предприятие'), findsOneWidget);
      expect(find.text('Отменено'), findsOneWidget);

      await tester.tap(find.text('Моя техника'));
      await tester.pumpAndSettle();
      expect(find.text('Ноутбук · Инв. № ИТ-0042 · каб. 214'), findsOneWidget);
      await tester.tap(find.byKey(const Key('ta_mine_report_5')));
      await settle(tester);
    }, server);
    final form =
        tester.widget<ItRequestFormScreen>(find.byType(ItRequestFormScreen));
    expect(form.description, 'HP ProBook 450, Инв. № ИТ-0042: ');
  });

  testWidgets('энергетик объявляет отключение для цеха', (tester) async {
    final server = FakeServer.routed((method, url, body) {
      if (url.path.endsWith('/departments')) {
        return (
          200,
          jsonEncode({
            'message': 'Success',
            'departments': ['Бухгалтерия', op]
          })
        );
      }
      if (method == 'POST') {
        return (201, jsonEncode({'message': 'Success', 'notified': 17}));
      }
      if (url.path.endsWith('/mine')) {
        return (
          200,
          jsonEncode({'message': 'Success', 'staff': false, 'items': []})
        );
      }
      return (
        200,
        jsonEncode({'message': 'Success', 'staff': true, 'items': []})
      );
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, TechScreen(now: DateTime(2030, 3, 4, 10)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ta_announce')));
      await settle(tester);
      await tester.pumpAndSettle();
      expect(find.text('05.03.2030 09:00'), findsOneWidget);
      await tester.tap(find.byKey(const Key('ta_kind_network')));
      await tester.tap(find.byKey(const Key('ta_dep_1')));
      await tester.enterText(
          find.byKey(const Key('ta_note')), 'Замена коммутатора');
      await tester.pump();
      await tester.tap(find.byKey(const Key('ta_send')));
      await settle(tester);
      await tester.pumpAndSettle();
    }, server);
    expect(jsonDecode(server.requests.lastWhere((r) => r.isNotEmpty)), {
      'kind': 'network',
      'starts_at': '2030-03-05 09:00',
      'ends_at': '2030-03-05 13:00',
      'note': 'Замена коммутатора',
      'departments': [op],
    });
    expect(
        find.text('Объявлено: 17 человек получат оповещение'), findsOneWidget);
  });

  testWidgets('ОИТиС выдаёт технику', (tester) async {
    final server = FakeServer.routed((method, url, body) {
      if (url.path.endsWith('/people')) {
        return (
          200,
          jsonEncode({
            'message': 'Success',
            'people': [master]
          })
        );
      }
      if (method == 'POST') {
        return (200, jsonEncode({'message': 'Success'}));
      }
      if (url.path.endsWith('/mine')) {
        return (
          200,
          jsonEncode({'message': 'Success', 'staff': true, 'items': []})
        );
      }
      if (url.path.endsWith('/it-assets')) {
        return (
          200,
          jsonEncode({
            'message': 'Success',
            'items': [asset(7)]
          })
        );
      }
      return (
        200,
        jsonEncode({'message': 'Success', 'staff': false, 'items': []})
      );
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const TechScreen());
      await tester.tap(find.text('Учёт'));
      await tester.pumpAndSettle();
      expect(find.text('Ноутбук · Инв. № ИТ-0042 · каб. 214\nСвободно'),
          findsOneWidget);
      await tester.tap(find.byKey(const Key('ta_asset_7')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ta_asset_release')), findsNothing);
      await tester.tap(find.byKey(const Key('ta_asset_assign')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('person_0000000082')));
      await settle(tester);
    }, server);
    expect(jsonDecode(server.requests.lastWhere((r) => r.isNotEmpty)),
        {'action': 'assign', 'employee_id': '0000000082'});
  });
}
