import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:se_mobile/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app starts without crash', (tester) async {
    app.main();
    // Allow up to 5 s for async init (Firebase, SharedPreferences, etc.)
    await tester.pumpAndSettle(const Duration(seconds: 5));
    // App must show at least one Scaffold (login or main screen)
    expect(find.byType(Scaffold), findsAtLeastNWidgets(1));
  });
}
