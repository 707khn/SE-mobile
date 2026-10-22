import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/workwear_request.dart';
import 'package:se_mobile/screens/workwear_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';

import 'support/fake_server.dart';

/// Спецодежда: сроки замены, стирка с «заберите», выдача хозотделом.
void main() {
  Map<String, dynamic> issue(int id, String item, String due,
          {String? dueOn, Map<String, dynamic>? employee}) =>
      {
        'id': id,
        'item': item,
        'size': '52-54',
        'quantity': 1,
        'issued_on': '2029-02-01',
        'wear_months': dueOn == null ? null : 12,
        'due_on': dueOn,
        'due': due,
        'note': '',
        if (employee != null) 'employee': employee,
      };

  final worker = {
    'id': '0000000082',
    'name': 'Мастеров Иван',
    'job_title': 'Мастер'
  };

  test('разбор карточки', () {
    final card = WorkwearCard.fromJson({
      'staff': true,
      'issues': [issue(1, 'Костюм', 'soon', dueOn: '2030-02-01')],
      'laundry': [
        {'id': 3, 'kind': 'repair', 'items': 'Куртка', 'status': 'ready'}
      ],
    });
    expect(card.staff, isTrue);
    expect(card.issues.single.dueOn, DateTime(2030, 2, 1));
    expect(card.issues.single.wearMonths, 12);
    expect(card.laundry.single.status, 'ready');
  });

  test('надписи в обоих языках', () {
    final keys = LocaleString().keys;
    final ru = keys[Lang.ru]!.keys.where((k) => k.startsWith('ww_')).toSet();
    final kk = keys[Lang.kk]!.keys.where((k) => k.startsWith('ww_')).toSet();
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

  String text(WidgetTester tester, String key) =>
      tester.widget<Text>(find.byKey(Key(key))).data!;

  testWidgets('сотрудник видит сроки и готовую стирку', (tester) async {
    final server = FakeServer.routed((method, url, body) => (
          200,
          jsonEncode({
            'message': 'Success',
            'staff': false,
            'issues': [
              issue(1, 'Перчатки', 'overdue', dueOn: '2030-01-01'),
              issue(2, 'Каска', 'none'),
            ],
            'laundry': [
              {'id': 5, 'kind': 'wash', 'items': 'Костюм', 'status': 'ready'}
            ],
          })
        ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const WorkwearScreen());
    }, server);
    expect(find.byType(TabBar), findsNothing);
    expect(text(tester, 'ww_due_1'), 'Замена: 01.01.2030 · Срок замены вышел');
    expect(text(tester, 'ww_due_2'), 'До износа');
    expect(text(tester, 'ww_status_5'), 'Готово, заберите');
  });

  testWidgets('хозотдел: готово из стирки и выдача', (tester) async {
    final server = FakeServer.routed((method, url, body) {
      if (url.path.endsWith('/staff')) {
        return (
          200,
          jsonEncode({
            'message': 'Success',
            'laundry': [
              {
                'id': 7,
                'kind': 'repair',
                'items': 'Куртка — молния',
                'status': 'accepted',
                'employee': worker,
              }
            ],
            'due': [
              issue(9, 'Костюм', 'soon', dueOn: '2030-02-01', employee: worker)
            ],
          })
        );
      }
      if (url.path.endsWith('/people')) {
        return (
          200,
          jsonEncode({
            'message': 'Success',
            'people': [worker]
          })
        );
      }
      if (method == 'POST') {
        return (201, jsonEncode({'message': 'Success'}));
      }
      return (
        200,
        jsonEncode(
            {'message': 'Success', 'staff': true, 'issues': [], 'laundry': []})
      );
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const WorkwearScreen());
      await tester.tap(find.text('Хозотдел'));
      await tester.pumpAndSettle();
      expect(find.text('Куртка — молния'), findsOneWidget);
      await tester.tap(find.byKey(const Key('ww_laundry_7')));
      await settle(tester);
      expect(jsonDecode(server.requests.lastWhere((r) => r.isNotEmpty)),
          {'action': 'ready'});

      await tester.tap(find.byKey(const Key('ww_issue')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('person_0000000082')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('field_item')), 'Ботинки');
      await tester.enterText(find.byKey(const Key('field_wear_months')), '24');
      await tester.pump();
      await tester.tap(find.byKey(const Key('fields_ok')));
      await settle(tester);
    }, server);
    expect(jsonDecode(server.requests.lastWhere((r) => r.isNotEmpty)), {
      'employee_id': '0000000082',
      'item': 'Ботинки',
      'size': '',
      'quantity': '1',
      'wear_months': '24',
    });
  });
}
