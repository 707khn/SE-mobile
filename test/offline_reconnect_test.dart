import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:se_mobile/utils/connection_watch.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';
import 'package:se_mobile/widgets/offline_notice.dart';

/// Пометка «показано сохранённое» не висит вечно: когда сервер снова
/// ответил, экран обновляется сам.
void main() {
  setUpAll(Lang.initDates);

  Widget host(DateTime? at, VoidCallback onRetry) => GetMaterialApp(
        translations: LocaleString(),
        locale: const Locale('ru'),
        home: Scaffold(body: OfflineNotice(at: at, onRetry: onRetry)),
      );

  testWidgets('связи нет — ждём; вернулась — обновляем', (tester) async {
    var online = false;
    var probes = 0;
    ConnectionWatch.probe = () async {
      probes++;
      return online;
    };
    var retries = 0;

    await tester
        .pumpWidget(host(DateTime(2026, 10, 1, 7, 40), () => retries++));
    expect(ConnectionWatch.instance.holders, 1);

    await tester.pump(ConnectionWatch.delays.first);
    expect(probes, 1);
    expect(retries, 0);

    online = true;
    await tester.pump(ConnectionWatch.delays[1]);
    expect(probes, 2);
    expect(retries, 1);

    // Свежие данные пришли — пометка ушла, следить больше незачем.
    await tester.pumpWidget(host(null, () => retries++));
    expect(ConnectionWatch.instance.holders, 0);
    await tester.pump(const Duration(minutes: 5));
    expect(probes, 2);
  });

  testWidgets('кнопка на пометке обновляет сразу', (tester) async {
    ConnectionWatch.probe = () async => false;
    var retries = 0;
    await tester
        .pumpWidget(host(DateTime(2026, 10, 1, 7, 40), () => retries++));

    await tester.tap(find.byIcon(Icons.refresh));
    expect(retries, 1);

    await tester.pumpWidget(const SizedBox());
    expect(ConnectionWatch.instance.holders, 0);
  });
}
