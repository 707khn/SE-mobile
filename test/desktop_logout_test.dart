import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/main.dart';
import 'package:se_mobile/screens/home_shell.dart';
import 'package:se_mobile/screens/start_screen.dart';
import 'package:se_mobile/utils/desktop.dart';
import 'package:se_mobile/widgets/app_drawer.dart';

/// «Выйти» в панели слева на компьютере.
///
/// На Windows 10 окно после выхода переставало отвечать: на экране
/// оставались панель вошедшего и форма входа. Это ровно тот миг, когда
/// оболочка закрывается и панель убирается — а навигатор со всеми экранами
/// переезжал в дереве на новое место. Теперь он стоит на месте.
void main() {
  setUp(() => debugDesktopOverride = true);
  tearDown(() => debugDesktopOverride = false);

  Finder sidebar() =>
      find.byWidgetPredicate((w) => w is AppDrawer && w.permanent);

  Future<void> step(WidgetTester tester, [int n = 1]) async {
    for (var i = 0; i < n; i++) {
      await tester.runAsync(
          () => Future.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Цепочка виджетов над навигатором — по ней видно, переехал ли он.
  List<Type> path(WidgetTester tester) {
    final types = <Type>[];
    tester.element(find.byType(Navigator).first).visitAncestorElements((e) {
      types.add(e.widget.runtimeType);
      return true;
    });
    return types;
  }

  testWidgets('выход убирает панель, а навигатор не переезжает',
      (tester) async {
    tester.view.physicalSize = const Size(1920, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({
      'loggedIn': 'true',
      'fullName': 'Иванов Иван Иванович',
      'job': 'Инженер',
      'pin': '1234',
      'token': 't',
    });
    await initializeSharedPreferences();
    await tester.pumpWidget(const MyApp());
    await step(tester, 30);
    final before = path(tester);

    for (final d in ['1', '2', '3', '4']) {
      await tester.tap(find.text(d).last);
      await tester.pump(const Duration(milliseconds: 50));
    }
    await step(tester, 30);
    expect(find.byType(HomeShell), findsOneWidget);
    expect(sidebar(), findsOneWidget);
    expect(path(tester), before, reason: 'вход: навигатор на том же месте');

    await tester.tap(
        find.descendant(of: sidebar(), matching: find.text('Выйти')));
    await step(tester, 10);
    await tester.tap(find.widgetWithText(ElevatedButton, 'Выйти'));
    await step(tester, 40);

    expect(find.byType(StartPage), findsOneWidget);
    expect(find.byType(HomeShell), findsNothing);
    expect(sidebar(), findsNothing);
    expect(path(tester), before, reason: 'выход: навигатор на том же месте');
  });
}
