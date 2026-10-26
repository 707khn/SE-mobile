import 'dart:async';

import 'package:se_mobile/utils/desktop.dart';

/// Проверки идут на Linux — то есть, для приложения, «на компьютере». А
/// почти все они про телефон: камера в заявке, «Поделиться», отпечаток.
/// Поэтому по умолчанию притворяемся телефоном; проверки компьютерного
/// поведения включают его сами.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  debugDesktopOverride = false;
  await testMain();
}
