import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/documents_request.dart';
import 'package:se_mobile/screens/documents_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';
import 'package:se_mobile/widgets/load_error_view.dart';

import 'support/fake_server.dart';

/// Раздел «Документы»: что ждёт ознакомления — сверху, и отметка ставится.
void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
          () => Future.delayed(const Duration(milliseconds: 60)));
      await tester.pump();
    }
  }

  Future<void> open(WidgetTester tester, FakeServer server) async {
    await tester.runAsync(Lang.initDates);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.pumpWidget(GetMaterialApp(
        translations: LocaleString(),
        locale: const Locale('ru'),
        home: const DocumentsScreen(),
      ));
      await settle(tester);
    }, server);
  }

  Map<String, dynamic> doc(int id, String title, String category,
          {bool requiresAck = false, String? ackedAt}) =>
      {
        'id': id,
        'category': category,
        'category_name': category,
        'title': title,
        'number': '',
        'date': null,
        'filename': '$title.pdf',
        'size': 1024,
        'requires_ack': requiresAck,
        'acked': ackedAt != null,
        'acked_at': ackedAt,
        'created_at': '2026-10-20T05:00:00Z',
      };

  final categories = [
    {'key': 'order', 'name': 'Приказы'},
    {'key': 'template', 'name': 'Образцы заявлений'},
  ];

  testWidgets('не загрузилось — ошибка, а не «документов нет»', (tester) async {
    await open(tester, FakeServer(502, 'Bad Gateway'));
    expect(find.byType(LoadErrorView), findsOneWidget);
    expect(find.text('documents_empty'.tr), findsNothing);
  });

  testWidgets('приказ ждёт отметки, после «Ознакомлен» — дата', (tester) async {
    final server = FakeServer.routed((method, url, body) {
      if (method == 'POST' && url.path.endsWith('/ack')) {
        return (
          200,
          jsonEncode({
            'message': 'Success',
            'item': doc(1, 'О режиме работы', 'order',
                requiresAck: true, ackedAt: '2026-10-21T05:00:00Z'),
          })
        );
      }
      return (
        200,
        jsonEncode({
          'message': 'Success',
          'categories': categories,
          'pending': 1,
          'can_edit': false,
          'items': [
            doc(1, 'О режиме работы', 'order', requiresAck: true),
            doc(2, 'Заявление на отпуск', 'template'),
          ],
        })
      );
    });
    await open(tester, server);

    expect(find.text('documents_waiting'.trParams({'count': '1'}).toUpperCase()),
        findsOneWidget);
    expect(find.text('ОБРАЗЦЫ ЗАЯВЛЕНИЙ'), findsOneWidget);
    expect(documentsPending.value, 1);
    // Приказ — и в «ждут», и в своём разделе: кнопка на обеих карточках.
    expect(find.widgetWithText(OutlinedButton, 'documents_ack'.tr),
        findsNWidgets(2));

    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.tap(find.widgetWithText(OutlinedButton, 'documents_ack'.tr).first);
      await settle(tester);
      await tester.tap(find.widgetWithText(ElevatedButton, 'documents_ack'.tr));
      await settle(tester);
    }, server);

    expect(find.widgetWithText(OutlinedButton, 'documents_ack'.tr), findsNothing);
    expect(find.text('documents_acked_on'.trParams({'date': '21.10.2026'})),
        findsOneWidget);
    expect(documentsPending.value, 0);
  });
}
