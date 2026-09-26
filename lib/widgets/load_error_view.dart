import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../utils/app_theme.dart';
import '../utils/load_problem.dart';

/// Заголовок и подсказка для причины — одни и те же везде, где она
/// показывается: на экране ошибки, в окне входа, под формой смены пароля.
/// `null` — причина неизвестна.
(String, String) problemTexts(LoadProblem? problem) => switch (problem) {
      LoadProblem.offline =>
        ('problem_offline_title'.tr, 'problem_offline_hint'.tr),
      LoadProblem.slow => ('problem_slow_title'.tr, 'problem_slow_hint'.tr),
      LoadProblem.server =>
        ('problem_server_title'.tr, 'problem_server_hint'.tr),
      LoadProblem.denied =>
        ('problem_denied_title'.tr, 'problem_denied_hint'.tr),
      null => ('load_error'.tr, 'problem_generic_hint'.tr),
    };

/// Одной строкой — для места, где под сообщение отведена строка текста.
String problemMessage(LoadProblem? problem) {
  final (title, hint) = problemTexts(problem);
  return '$title. $hint';
}

/// Экран «не загрузилось»: что случилось, что с этим делать и кнопка повтора.
///
/// Одна на всё приложение. Прежде таких было три копии, чуть разные по
/// размеру значка и тексту, и все говорили одно — «ошибка подключения», —
/// что бы ни случилось на самом деле.
class LoadErrorView extends StatelessWidget {
  const LoadErrorView({Key? key, this.problem, required this.onRetry})
      : super(key: key);

  /// `null` — причина неизвестна, показываем общее «не удалось загрузить».
  final LoadProblem? problem;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final icon = switch (problem) {
      LoadProblem.offline => Icons.wifi_off_rounded,
      LoadProblem.slow => Icons.hourglass_bottom_rounded,
      LoadProblem.server => Icons.cloud_off_rounded,
      LoadProblem.denied => Icons.lock_outline_rounded,
      null => Icons.error_outline_rounded,
    };
    final (title, hint) = problemTexts(problem);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: context.mutedColor.withOpacity(0.55)),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: context.inkColor),
            ),
            const SizedBox(height: 6),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 14, height: 1.4, color: context.mutedColor),
            ),
            // Нет доступа — повтор ничего не изменит, кнопка только обнадёжит.
            if (problem != LoadProblem.denied) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: Text('try_again'.tr),
                style: OutlinedButton.styleFrom(
                  foregroundColor: context.accentColor,
                  side: BorderSide(
                      color: context.accentColor.withOpacity(0.5)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
