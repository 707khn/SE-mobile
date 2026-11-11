import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/utils/localization.dart';
import 'package:se_mobile/widgets/app_drawer.dart';

/// Боковое меню: группы без заголовков, рядом — то, что по смыслу вместе.
void main() {
  Future<List<String>> labels(WidgetTester tester, String job) async {
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues(
        {'fullName': 'Иванов Иван Иванович', 'job': job});
    await tester.pumpWidget(GetMaterialApp(
      translations: LocaleString(),
      locale: const Locale('ru'),
      home: const Scaffold(body: AppDrawer()),
    ));
    await tester.pump();
    await tester.pump();
    final tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
    return [for (final tile in tiles) (tile.title as Text).data!];
  }

  testWidgets('у начальника: проходы отдела — сразу под «Турникетом»',
      (tester) async {
    expect(await labels(tester, 'Начальник цеха'), [
      'Главная',
      'Турникет',
      'Отчёт по сотрудникам',
      'Зарплата',
      'Отпуск',
      'Меню',
      'Задачи',
      'Командировки',
      'Медосмотры',
      'Новости',
      'Справочник',
      'Техника и отключения',
      'Настройки',
      'Выйти',
    ]);
    // Заголовков групп больше нет — только черта между ними.
    for (final header in ['РУКОВОДИТЕЛЮ', 'ПРЕДПРИЯТИЕ', 'МОИ ДЕЛА']) {
      expect(find.text(header), findsNothing);
    }
  });

  testWidgets('у сотрудника пункта начальника нет', (tester) async {
    final items = await labels(tester, 'Слесарь');
    expect(items, isNot(contains('Отчёт по сотрудникам')));
    expect(items.take(3), ['Главная', 'Турникет', 'Зарплата']);
  });
}
