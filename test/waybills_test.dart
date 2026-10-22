import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/waybill_request.dart';
import 'package:se_mobile/screens/waybill_detail_screen.dart';
import 'package:se_mobile/screens/waybills_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';

import 'support/fake_server.dart';

/// Путевой лист: открыть после допуска, поездка, возврат, итоги дня.
void main() {
  Map<String, dynamic> waybill(int id, String status,
          {bool edit = false,
          bool review = false,
          List<Map<String, dynamic>> trips = const []}) =>
      {
        'id': id,
        'date': '2030-01-15',
        'plate': '123ABC02',
        'status': status,
        'odometer_out': 154200,
        'odometer_in': status == 'open' ? null : 154262,
        'fuel_out': 35.5,
        'fuel_added': status == 'open' ? null : 20,
        'fuel_in': status == 'open' ? null : 41.5,
        'distance': status == 'open' ? null : 62,
        'fuel_used': status == 'open' ? null : 14,
        'note': '',
        'driver': {'id': '0000000155', 'name': 'Водитель Тест'},
        'reviewer': null,
        'trips': trips,
        'can_edit': edit,
        'can_review': review,
      };

  const trip = {
    'id': 3,
    'origin': 'Завод',
    'destination': 'Налоговая',
    'purpose': 'Документы',
    'customer': 'ОБиНУ',
    'departed': '09:10',
    'arrived': '09:40',
  };

  test('разбор', () {
    final w = Waybill.fromJson(waybill(1, 'returned', trips: [trip]));
    expect(w.distance, 62);
    expect(w.trips.single.when, '09:10–09:40');
    expect(litres(41.5), '41,5');
    expect(litres(null), '—');
    final o = WaybillOverview.fromJson({
      'driver': true,
      'ready': {'admitted': true, 'released': true, 'examined': true},
    });
    expect(o.ready.canOpen, isTrue);
  });

  test('надписи в обоих языках', () {
    final keys = LocaleString().keys;
    final ru = keys[Lang.ru]!.keys.where((k) => k.startsWith('wb_')).toSet();
    final kk = keys[Lang.kk]!.keys.where((k) => k.startsWith('wb_')).toSet();
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

  testWidgets('водитель без допуска не может открыть лист', (tester) async {
    final server = FakeServer.routed((method, url, body) => (
          200,
          jsonEncode({
            'message': 'Success',
            'driver': true,
            'ready': {'examined': true, 'admitted': true, 'checked': false},
            'mine': [],
          })
        ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const WaybillsScreen());
    }, server);
    expect(find.text('Медпункт: допущен'), findsOneWidget);
    expect(find.text('Машина: ещё нет отметки'), findsOneWidget);
    expect(find.byKey(const Key('wb_cannot_open')), findsOneWidget);
    expect(find.byKey(const Key('wb_open')), findsNothing);
  });

  testWidgets('водитель открывает лист с пробегом из выпуска', (tester) async {
    final server = FakeServer.routed((method, url, body) {
      if (method == 'POST') {
        return (
          201,
          jsonEncode({'message': 'Success', 'item': waybill(8, 'open')})
        );
      }
      if (url.path.endsWith('/8')) {
        return (
          200,
          jsonEncode(
              {'message': 'Success', 'item': waybill(8, 'open', edit: true)})
        );
      }
      return (
        200,
        jsonEncode({
          'message': 'Success',
          'driver': true,
          'ready': {
            'examined': true,
            'admitted': true,
            'checked': true,
            'released': true,
            'plate': '123ABC02',
            'odometer': 154200,
            'fuel': 35.5,
          },
          'mine': [],
        })
      );
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const WaybillsScreen());
      expect(find.text('Сегодня · 123ABC02'), findsOneWidget);
      await tester.tap(find.byKey(const Key('wb_open')));
      await tester.pumpAndSettle();
      expect(find.text('154200'), findsOneWidget);
      expect(find.text('35,5'), findsOneWidget);
      await tester.tap(find.byKey(const Key('fields_ok')));
      await settle(tester);
      await tester.pumpAndSettle();
    }, server);
    expect(server.requests.where((b) => b.isNotEmpty).map(jsonDecode).first,
        {'fuel_out': '35,5', 'odometer_out': '154200'});
    expect(find.byKey(const Key('wb_trip_add')), findsOneWidget);
  });

  testWidgets('поездка и возврат', (tester) async {
    final server = FakeServer.routed((method, url, body) {
      if (method == 'POST') {
        final sent = jsonDecode(body) as Map<String, dynamic>;
        return (
          200,
          jsonEncode({
            'message': 'Success',
            'item': sent['action'] == 'return'
                ? waybill(8, 'returned', trips: [trip])
                : waybill(8, 'open', edit: true, trips: [trip])
          })
        );
      }
      return (
        200,
        jsonEncode(
            {'message': 'Success', 'item': waybill(8, 'open', edit: true)})
      );
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const WaybillDetailScreen(waybillId: 8));
      expect(find.text('Поездок пока нет'), findsOneWidget);
      await tester.tap(find.byKey(const Key('wb_trip_add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('field_origin')), 'Завод');
      await tester.enterText(
          find.byKey(const Key('field_destination')), 'Налоговая');
      await tester.enterText(find.byKey(const Key('field_departed')), '09:10');
      await tester.pump();
      await tester.tap(find.byKey(const Key('fields_ok')));
      await settle(tester);
      await tester.pumpAndSettle();
      expect(find.text('Завод → Налоговая'), findsOneWidget);

      await tester.tap(find.byKey(const Key('wb_return')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('field_odometer_in')), '154262');
      await tester.enterText(find.byKey(const Key('field_fuel_added')), '20');
      await tester.enterText(find.byKey(const Key('field_fuel_in')), '41,5');
      await tester.pump();
      await tester.tap(find.byKey(const Key('fields_ok')));
      await settle(tester);
      await tester.pumpAndSettle();
    }, server);
    final posts = server.requests
        .where((b) => b.isNotEmpty)
        .map((b) => jsonDecode(b) as Map<String, dynamic>)
        .toList();
    expect(posts.first['action'], 'trip');
    expect(posts.first['origin'], 'Завод');
    expect(posts.first['departed'], '09:10');
    expect(posts.last, {
      'action': 'return',
      'odometer_in': '154262',
      'fuel_added': '20',
      'fuel_in': '41,5',
    });
    expect(find.byKey(const Key('wb_used')), findsOneWidget);
    expect(find.text('расход 14 л'), findsOneWidget);
    expect(find.byKey(const Key('wb_trip_add')), findsNothing);
  });

  testWidgets('механик видит итоги дня и закрывает', (tester) async {
    final server = FakeServer.routed((method, url, body) {
      if (url.path.endsWith('/waybills')) {
        return (
          200,
          jsonEncode({
            'message': 'Success',
            'staff': true,
            'date': '2030-01-15',
            'items': [waybill(8, 'returned', review: true)],
            'totals': {
              'count': 1,
              'open': 0,
              'returned': 1,
              'distance': 62,
              'fuel_used': 14
            },
          })
        );
      }
      return (
        200,
        jsonEncode({
          'message': 'Success',
          'item': method == 'POST'
              ? waybill(8, 'closed')
              : waybill(8, 'returned', review: true)
        })
      );
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const WaybillsScreen());
      expect(tester.widget<Text>(find.byKey(const Key('wb_totals'))).data,
          'Листов: 1 · в рейсе: 0 · на проверку: 1 · 62 км · 14 л');
      await tester.tap(find.text('Водитель Т. · 123ABC02'));
      await settle(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('wb_close')));
      await settle(tester);
    }, server);
    expect(jsonDecode(server.requests.last), {'action': 'close'});
    expect(find.text('Закрыт'), findsOneWidget);
  });
}
