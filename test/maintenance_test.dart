import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/maintenance_request.dart';
import 'package:se_mobile/screens/maintenance_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';
import 'package:se_mobile/utils/role_helper.dart';

import 'support/fake_server.dart';

/// График ППР: ближайшие остановки, «выполнено», история.
void main() {
  final equipment = {
    'id': 4,
    'name': 'Токарный станок 16К20',
    'inventory_no': 'ИН-0042',
    'location': 'Участок 3',
    'master': {'id': '0000000082', 'name': 'Мастеров Иван'},
    'engineer': null,
  };

  Map<String, dynamic> plan(int id, String state, String next,
          {bool canMark = false,
          List<Map<String, dynamic>> history = const []}) =>
      {
        'id': id,
        'equipment_id': 4,
        'kind': 'service',
        'every_months': 3,
        'next_on': next,
        'hours': 8,
        'note': '',
        'state': state,
        'equipment': equipment,
        'can_mark': canMark,
        'history': history,
      };

  test('разбор и кому пункт меню', () {
    final p = MaintenancePlan.fromJson(plan(1, 'week', '2030-01-20'));
    expect(p.nextOn, DateTime(2030, 1, 20));
    expect(p.equipment!.master!.name, 'Мастеров Иван');
    expect(usesMaintenance('Мастер'), isTrue);
    expect(usesMaintenance('Главный энергетик'), isTrue);
    expect(usesMaintenance('Водитель'), isFalse);
  });

  test('надписи в обоих языках', () {
    final keys = LocaleString().keys;
    final ru = keys[Lang.ru]!.keys.where((k) => k.startsWith('pm_')).toSet();
    final kk = keys[Lang.kk]!.keys.where((k) => k.startsWith('pm_')).toSet();
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

  testWidgets('график по группам', (tester) async {
    final server = FakeServer.routed((method, url, body) => (
          200,
          jsonEncode({
            'message': 'Success',
            'planner': false,
            'items': [
              plan(1, 'overdue', '2030-01-10'),
              plan(2, 'week', '2030-01-20'),
            ],
          })
        ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const MaintenanceScreen());
    }, server);
    expect(find.text('Просрочено'), findsOneWidget);
    expect(find.text('На этой неделе'), findsOneWidget);
    expect(find.text('Позже'), findsNothing);
    expect(tester.widget<Text>(find.byKey(const Key('pm_date_2'))).data,
        '20.01.2030');
    expect(find.text('Техобслуживание · ≈ 8 ч · Участок 3'), findsNWidgets(2));
  });

  testWidgets('ответственный отмечает «выполнено»', (tester) async {
    var done = false;
    final server = FakeServer.routed((method, url, body) {
      if (method == 'POST') {
        done = true;
        return (200, jsonEncode({'message': 'Success'}));
      }
      return (
        200,
        jsonEncode({
          'message': 'Success',
          'planner': false,
          'item': {
            ...equipment,
            'plans': [
              done
                  ? plan(1, 'later', '2030-04-15', history: [
                      {
                        'action': 'done',
                        'planned_on': '2030-01-20',
                        'done_on': '2030-01-15',
                        'note': 'Заменили масло',
                        'actor': {'id': '1', 'name': 'Энергетиков Пётр'},
                      }
                    ])
                  : plan(1, 'week', '2030-01-20', canMark: true),
            ],
          },
        })
      );
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const EquipmentScreen(equipmentId: 4));
      expect(find.byKey(const Key('pm_postpone_1')), findsNothing);
      expect(find.byKey(const Key('pm_add_plan')), findsNothing);
      await tester.tap(find.byKey(const Key('pm_done_1')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('field_note')), 'Заменили масло');
      await tester.pump();
      await tester.tap(find.byKey(const Key('fields_ok')));
      await settle(tester);
      await tester.pumpAndSettle();
    }, server);
    expect(jsonDecode(server.requests.lastWhere((r) => r.isNotEmpty)),
        {'action': 'done', 'note': 'Заменили масло'});
    expect(tester.widget<Text>(find.byKey(const Key('pm_next_1'))).data,
        'Следующий: 15.04.2030');
    expect(
        find.text('Выполнено 15.01.2030 · Энергетиков Пётр · Заменили масло'),
        findsOneWidget);
  });
}
